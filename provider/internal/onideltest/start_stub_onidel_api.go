package onideltest

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"maps"
	"net"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"sync"
	"testing"

	"github.com/getkin/kin-openapi/openapi3"
	"github.com/getkin/kin-openapi/openapi3filter"
	"github.com/getkin/kin-openapi/routers"
	"github.com/getkin/kin-openapi/routers/legacy"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/zgeoff/cloud/provider/internal/onidelapi"
)

// StubOnidelAPI is an in-memory Onidel API, written against provider/spec/onidel.yaml and
// shaped after live responses: GET /vm returns a bare array, a VM object carries the
// root password in plain text, a missing VM is a 404 with an empty body, and POST /vm
// is a 201 with no body.
//
// A VM settles on the first read of GET /vm/{id} after it changes: that read reports
// the in-flight state (status building, or an active_action_id), and the next read
// sees it active with no action. SetAutoSettle(false) holds every VM where it is.
//
// The stub records every request and validates it against the spec the client is
// generated from: onidel.yaml with the overlay applied, for the operations in use
// (onidelapi.GetSpec). A request that does not match the spec, a request no route
// serves, a VM setting the stub does not model, or a body that is not JSON, is a
// problem: it gets a 400 or a 500, and the test fails at cleanup unless it drains the
// problem with DrainProblems.
type StubOnidelAPI struct {
	// URL is the base URL of the running stub.
	URL string

	mu         sync.Mutex
	seq        int
	autoSettle bool
	teams      []map[string]any
	vms        map[string]map[string]any
	vmOrder    []string
	firewalls  map[string]map[string]any
	rules      map[string]map[string]any
	snapshots  []map[string]any
	requests   []Request
	problems   []string
	// canned holds, per pattern, the status and body of each response still to send.
	canned map[string][]struct {
		status int
		body   string
	}

	routes    *http.ServeMux
	overrides *http.ServeMux
	cans      *http.ServeMux
	spec      routers.Router
}

// StartStubOnidelAPI starts a stub API with no teams and no resources: the spec does
// not document what a fresh account lists, so a test that needs a team sets it with
// SetTeams. When the test ends, it fails the test on any problem left undrained, then
// stops the server.
func StartStubOnidelAPI(t testing.TB) *StubOnidelAPI {
	t.Helper()
	spec, err := onidelapi.GetSpec()
	require.NoError(t, err)
	// The spec names the production server; the stub serves the same paths on loopback.
	spec.Servers = nil
	router, err := legacy.NewRouter(spec)
	require.NoError(t, err)
	f := &StubOnidelAPI{
		autoSettle: true,
		teams:      []map[string]any{},
		vms:        map[string]map[string]any{},
		firewalls:  map[string]map[string]any{},
		rules:      map[string]map[string]any{},
		canned: map[string][]struct {
			status int
			body   string
		}{},
		routes:    http.NewServeMux(),
		overrides: http.NewServeMux(),
		cans:      http.NewServeMux(),
		spec:      router,
	}
	f.registerRoutes()
	server := httptest.NewServer(f)
	t.Cleanup(server.Close)
	t.Cleanup(func() {
		t.Helper()
		assert.Empty(t, f.DrainProblems(), "the stub API saw requests it does not serve")
	})
	f.URL = server.URL
	return f
}

// RegisterResponse answers the next times requests that match pattern (a ServeMux
// pattern such as "GET /teams") with status and body, before the pattern falls back
// to the stub's own route. Responses registered for one pattern are sent in order.
func (f *StubOnidelAPI) RegisterResponse(pattern string, status int, body string, times int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if _, ok := f.canned[pattern]; !ok {
		f.cans.HandleFunc(pattern, func(http.ResponseWriter, *http.Request) {})
	}
	f.canned[pattern] = append(f.canned[pattern], slices.Repeat([]struct {
		status int
		body   string
	}{{status, body}}, times)...)
}

// RegisterHandler serves pattern (a net/http ServeMux pattern such as "POST /vm") with
// h instead of the stub's own route, so a test can stand in for one deviation: an
// error status or an undocumented payload. h runs without the stub's lock, so it may
// call the stub's setters.
func (f *StubOnidelAPI) RegisterHandler(pattern string, h http.HandlerFunc) {
	f.overrides.HandleFunc(pattern, h)
}

// SetAutoSettle chooses whether VMs settle on read (the default) or hold their
// in-flight state.
func (f *StubOnidelAPI) SetAutoSettle(enabled bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.autoSettle = enabled
}

// SetTeams replaces the teams GET /teams lists. With no teams, it lists an empty array.
func (f *StubOnidelAPI) SetTeams(teams ...map[string]any) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.teams = append([]map[string]any{}, teams...)
}

// SetVM stores vm under its "id", replacing any VM with that ID.
func (f *StubOnidelAPI) SetVM(vm map[string]any) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.setVM(maps.Clone(vm))
}

func (f *StubOnidelAPI) setVM(vm map[string]any) {
	id := vm["id"].(string)
	if _, ok := f.vms[id]; !ok {
		f.vmOrder = append(f.vmOrder, id)
	}
	f.vms[id] = vm
}

// SetFirewallGroup stores group under its "id", replacing any group with that ID.
func (f *StubOnidelAPI) SetFirewallGroup(group map[string]any) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.firewalls[group["id"].(string)] = maps.Clone(group)
}

// SetFirewallRule stores rule under its "id", replacing any rule with that ID. The
// rule's "group" names the group it belongs to; the group's rule_count is left as
// the test set it.
func (f *StubOnidelAPI) SetFirewallRule(rule map[string]any) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.rules[rule["id"].(string)] = maps.Clone(rule)
}

// GetRequests returns every request received so far, in order.
func (f *StubOnidelAPI) GetRequests() []Request {
	f.mu.Lock()
	defer f.mu.Unlock()
	return slices.Clone(f.requests)
}

// DrainProblems returns the problems seen so far and clears them, so a test that
// provokes one on purpose can assert it and still pass the cleanup check.
func (f *StubOnidelAPI) DrainProblems() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	problems := f.problems
	f.problems = nil
	return problems
}

func buildStoreCopy(store map[string]map[string]any) map[string]map[string]any {
	out := make(map[string]map[string]any, len(store))
	for id, item := range store {
		out[id] = maps.Clone(item)
	}
	return out
}

// GetVMs returns the stored VMs by ID.
func (f *StubOnidelAPI) GetVMs() map[string]map[string]any {
	f.mu.Lock()
	defer f.mu.Unlock()
	return buildStoreCopy(f.vms)
}

// GetFirewallGroups returns the stored firewall groups by ID.
func (f *StubOnidelAPI) GetFirewallGroups() map[string]map[string]any {
	f.mu.Lock()
	defer f.mu.Unlock()
	return buildStoreCopy(f.firewalls)
}

// GetSnapshots returns the snapshots taken so far, in order.
func (f *StubOnidelAPI) GetSnapshots() []map[string]any {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := make([]map[string]any, 0, len(f.snapshots))
	for _, snapshot := range f.snapshots {
		out = append(out, maps.Clone(snapshot))
	}
	return out
}

// GetFirewallRules returns the stored firewall rules by ID.
func (f *StubOnidelAPI) GetFirewallRules() map[string]map[string]any {
	f.mu.Lock()
	defer f.mu.Unlock()
	return buildStoreCopy(f.rules)
}

// APIKey is the bearer token the stub API accepts. Any other token gets a 401.
const APIKey = "test-key"

// ServeHTTP records the request, then answers it: 400 for a body that is not a JSON
// object or a request that does not match the spec, 401 for a wrong bearer token, else
// the registered override or the route.
func (f *StubOnidelAPI) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	raw, _ := io.ReadAll(r.Body)
	body, ok := decodeBody(raw)
	f.mu.Lock()
	f.requests = append(f.requests, Request{Method: r.Method, Path: r.URL.Path, Query: r.URL.RawQuery, Body: body})
	if !ok {
		f.problems = append(f.problems, fmt.Sprintf("body is not a JSON object: %s %s", r.Method, r.URL.Path))
	}
	f.mu.Unlock()

	if !ok {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	if err := f.checkRequest(r, raw); err != nil {
		f.mu.Lock()
		f.problems = append(f.problems, fmt.Sprintf("request does not match the spec: %s %s: %s", r.Method, r.URL.Path, err))
		f.mu.Unlock()
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	if r.Header.Get("Authorization") != "Bearer "+APIKey {
		w.WriteHeader(http.StatusUnauthorized)
		return
	}
	r.Body = io.NopCloser(bytes.NewReader(raw))
	if status, body, ok := f.claimCannedResponse(r); ok {
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
		return
	}
	if h, pattern := f.overrides.Handler(r); pattern != "" {
		h.ServeHTTP(w, r)
		return
	}
	f.routes.ServeHTTP(w, r)
}

// checkRequest validates r, whose body is raw, against the operation of the spec it
// matches, and leaves r's body readable again. A request that matches no operation
// passes: no route serves it, so the stub reports it as unhandled instead. The error
// names the failing rule and where it failed, never the value.
func (f *StubOnidelAPI) checkRequest(r *http.Request, raw []byte) error {
	defer func() { r.Body = io.NopCloser(bytes.NewReader(raw)) }()
	route, params, err := f.spec.FindRoute(r)
	if err != nil {
		return nil
	}
	r.Body = io.NopCloser(bytes.NewReader(raw))
	err = openapi3filter.ValidateRequest(r.Context(), &openapi3filter.RequestValidationInput{
		Request: r, PathParams: params, Route: route,
		Options: &openapi3filter.Options{AuthenticationFunc: openapi3filter.NoopAuthenticationFunc},
	})
	var schemaErr *openapi3.SchemaError
	if errors.As(err, &schemaErr) {
		return fmt.Errorf("%s at /%s", schemaErr.Reason, strings.Join(schemaErr.JSONPointer(), "/"))
	}
	var reqErr *openapi3filter.RequestError
	if errors.As(err, &reqErr) {
		return errors.New(reqErr.Reason)
	}
	return err
}

func decodeBody(raw []byte) (map[string]any, bool) {
	if len(bytes.TrimSpace(raw)) == 0 {
		return nil, true
	}
	var body map[string]any
	if err := json.Unmarshal(raw, &body); err != nil || body == nil {
		return nil, false
	}
	return body, true
}

func (f *StubOnidelAPI) claimCannedResponse(r *http.Request) (int, string, bool) {
	_, pattern := f.cans.Handler(r)
	f.mu.Lock()
	defer f.mu.Unlock()
	queue := f.canned[pattern]
	if pattern == "" || len(queue) == 0 {
		return 0, "", false
	}
	f.canned[pattern] = queue[1:]
	return queue[0].status, queue[0].body, true
}

func (f *StubOnidelAPI) registerRoutes() {
	route := func(pattern string, h func(w http.ResponseWriter, r *http.Request, body map[string]any)) {
		f.routes.HandleFunc(pattern, func(w http.ResponseWriter, r *http.Request) {
			raw, _ := io.ReadAll(r.Body)
			body, _ := decodeBody(raw)
			f.mu.Lock()
			defer f.mu.Unlock()
			h(w, r, body)
		})
	}

	route("/", f.checkUnhandled)
	route("GET /teams", f.sendTeams)
	route("GET /os_templates", f.sendOSTemplates)

	route("GET /vm", f.sendVMs)
	route("POST /vm", f.createVM)
	route("GET /vm/{id}", f.sendVM)
	route("PATCH /vm/{id}", f.updateVM)
	route("DELETE /vm/{id}", f.removeVM)
	route("POST /vm/{id}/snapshot", f.createSnapshot)
	route("GET /snapshots", f.sendSnapshots)

	route("POST /network/firewalls", f.createFirewallGroup)
	route("GET /network/firewalls/{id}", f.sendFirewallGroup)
	route("PUT /network/firewalls/{id}", f.updateFirewallGroup)
	route("DELETE /network/firewalls/{id}", f.removeFirewallGroup)

	route("POST /network/firewalls/{id}/rules", f.createFirewallRule)
	route("GET /network/firewalls/{id}/rules/{rule}", f.sendFirewallRule)
	route("PATCH /network/firewalls/{id}/rules/{rule}", f.updateFirewallRule)
	route("DELETE /network/firewalls/{id}/rules/{rule}", f.removeFirewallRule)
}

func (f *StubOnidelAPI) checkUnhandled(w http.ResponseWriter, r *http.Request, _ map[string]any) {
	target := r.URL.Path
	if r.URL.RawQuery != "" {
		target += "?" + r.URL.RawQuery
	}
	f.problems = append(f.problems, fmt.Sprintf("unhandled request: %s %s", r.Method, target))
	w.WriteHeader(http.StatusInternalServerError)
}

func (f *StubOnidelAPI) sendTeams(w http.ResponseWriter, _ *http.Request, _ map[string]any) {
	sendJSON(w, http.StatusOK, f.teams)
}

func sendJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func (f *StubOnidelAPI) sendOSTemplates(w http.ResponseWriter, _ *http.Request, _ map[string]any) {
	sendJSON(w, http.StatusOK, []any{
		map[string]any{"id": 3, "name": "Ubuntu 24.04 LTS x64", "family": "Ubuntu"},
		map[string]any{"id": 24, "name": "Ubuntu 26.04 LTS x64", "family": "Ubuntu"},
	})
}

func hasStrings(body map[string]any, keys ...string) bool {
	for _, key := range keys {
		if s, _ := body[key].(string); s == "" {
			return false
		}
	}
	return true
}

func (f *StubOnidelAPI) claimID() string {
	f.seq++
	return fmt.Sprintf("00000000-0000-4000-8000-%012d", f.seq)
}

// sendVMs lists VMs in the order they were stored.
func (f *StubOnidelAPI) sendVMs(w http.ResponseWriter, _ *http.Request, _ map[string]any) {
	list := []any{}
	for _, id := range f.vmOrder {
		list = append(list, f.vms[id])
	}
	sendJSON(w, http.StatusOK, list)
}

// createVM provisions a VM in status building. NewVM documents "provide one of os,
// snapshot_id or iso_id", so any other count is a 400.
func (f *StubOnidelAPI) createVM(w http.ResponseWriter, _ *http.Request, body map[string]any) {
	sources := 0
	for _, key := range []string{"os", "snapshot_id", "iso_id"} {
		if _, ok := body[key]; ok {
			sources++
		}
	}
	if sources != 1 {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	ipv6 := ""
	if body["ipv6"] == true {
		ipv6 = "2401:db8::1"
	}
	firewall := body["firewall_group_id"]
	f.setVM(map[string]any{
		"id": f.claimID(), "name": body["name"], "vcpu": body["cpu"], "ram": body["ram"], "disk": body["disk"],
		"location": body["location"], "password": "fixture-root-pw-do-not-leak", "main_ipv4": "203.0.113.10",
		"main_ipv6": ipv6, "template": "Ubuntu 26.04 LTS x64", "firewall_group_id": firewall,
		"created_at": "2026-10-02T05:48:53Z", "status": "building", "active_action_id": nil,
		"bgp_enabled": false,
	})
	f.updateInstanceCount(firewall, 1)
	w.WriteHeader(http.StatusCreated)
}

// updateInstanceCount moves a group's instance_count when a VM attaches or detaches.
// A VM may report its group by a numeric ID no stored group has; that changes nothing.
func (f *StubOnidelAPI) updateInstanceCount(groupID any, delta int) {
	id, _ := groupID.(string)
	group, ok := f.firewalls[id]
	if !ok {
		return
	}
	count, _ := group["instance_count"].(int)
	group["instance_count"] = count + delta
}

func (f *StubOnidelAPI) sendVM(w http.ResponseWriter, r *http.Request, _ map[string]any) {
	vm, ok := f.vms[r.PathValue("id")]
	if !ok {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	sendJSON(w, http.StatusOK, vm)
	if f.autoSettle && isSettling(vm) {
		vm["status"] = "active"
		vm["active_action_id"] = nil
	}
}

// isSettling reports whether the VM is in a status the client waits on, or runs an action.
func isSettling(vm map[string]any) bool {
	status, _ := vm["status"].(string)
	return onidelapi.VMStatus(status).IsSettling() || vm["active_action_id"] != nil
}

// updateVM applies one setting per request (202), refuses a VM with an action in
// flight (409), and starts an action that the next read settles.
func (f *StubOnidelAPI) updateVM(w http.ResponseWriter, r *http.Request, body map[string]any) {
	vm, ok := f.vms[r.PathValue("id")]
	if !ok {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	if vm["active_action_id"] != nil {
		w.WriteHeader(http.StatusConflict)
		return
	}
	settings := maps.Clone(body)
	delete(settings, "team_id")
	if len(settings) != 1 {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	for key, value := range settings {
		switch key {
		case "name":
			vm["name"] = value
		case "enable_ipv6":
			vm["main_ipv6"] = ""
			if value == true {
				vm["main_ipv6"] = "2401:db8::1"
			}
		case "firewall_group_id":
			f.updateInstanceCount(vm["firewall_group_id"], -1)
			vm["firewall_group_id"] = value
			f.updateInstanceCount(value, 1)
		case "disable_firewall":
			f.updateInstanceCount(vm["firewall_group_id"], -1)
			vm["firewall_group_id"] = nil
		default:
			// The spec accepts more settings (os_id, use_uefi, enable_sev) than the stub models.
			f.problems = append(f.problems, fmt.Sprintf("unmodelled VM setting: PATCH %s %s", r.URL.Path, key))
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
	}
	vm["active_action_id"] = 42
	w.WriteHeader(http.StatusAccepted)
}

// createSnapshot starts a snapshot of a stored VM. The snapshot lists as pending, and
// the VM reads as taking_snaphot, the spec's spelling, until a read settles it.
func (f *StubOnidelAPI) createSnapshot(w http.ResponseWriter, r *http.Request, body map[string]any) {
	vm, ok := f.vms[r.PathValue("id")]
	if !ok {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	desc, _ := body["desc"].(string)
	snapshot := map[string]any{
		"id": f.claimID(), "created_at": "2026-10-02T06:00:00Z", "name": body["name"], "desc": desc,
		"size": vm["disk"], "status": "pending",
	}
	f.snapshots = append(f.snapshots, snapshot)
	vm["status"] = "taking_snaphot"
	sendJSON(w, http.StatusCreated, map[string]any{"snapshot_id": snapshot["id"]})
}

// sendSnapshots lists the snapshots in the order they were taken.
func (f *StubOnidelAPI) sendSnapshots(w http.ResponseWriter, _ *http.Request, _ map[string]any) {
	sendJSON(w, http.StatusOK, append([]map[string]any{}, f.snapshots...))
}

func (f *StubOnidelAPI) removeVM(w http.ResponseWriter, r *http.Request, _ map[string]any) {
	id := r.PathValue("id")
	vm, ok := f.vms[id]
	if !ok {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	f.updateInstanceCount(vm["firewall_group_id"], -1)
	delete(f.vms, id)
	f.vmOrder = slices.DeleteFunc(f.vmOrder, func(v string) bool { return v == id })
	w.WriteHeader(http.StatusNoContent)
}

// createFirewallGroup needs a team_id, past the spec's description: the live API
// answers 401, not 400, when team_id is missing (checked 2026-10-02).
func (f *StubOnidelAPI) createFirewallGroup(w http.ResponseWriter, _ *http.Request, body map[string]any) {
	if !hasStrings(body, "team_id") {
		sendJSON(w, http.StatusUnauthorized, map[string]any{"err": "UNAUTHORIZED"})
		return
	}
	group := map[string]any{
		"id": f.claimID(), "description": body["description"], "created": "2026-10-02T00:00:00Z",
		"updated": "2026-10-02T00:00:00Z", "instance_count": 0, "rule_count": 0,
	}
	f.firewalls[group["id"].(string)] = group
	sendJSON(w, http.StatusCreated, map[string]any{"firewall_group": group})
}

func (f *StubOnidelAPI) sendFirewallGroup(w http.ResponseWriter, r *http.Request, _ map[string]any) {
	group, ok := f.firewalls[r.PathValue("id")]
	if !ok {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	sendJSON(w, http.StatusOK, map[string]any{"firewall_group": group})
}

// updateFirewallGroup changes the description, which the spec requires.
func (f *StubOnidelAPI) updateFirewallGroup(w http.ResponseWriter, r *http.Request, body map[string]any) {
	group, ok := f.firewalls[r.PathValue("id")]
	if !ok {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	group["description"] = body["description"]
	group["updated"] = "2026-10-03T00:00:00Z"
	w.WriteHeader(http.StatusNoContent)
}

// removeFirewallGroup refuses while VMs are attached (400, per the spec).
func (f *StubOnidelAPI) removeFirewallGroup(w http.ResponseWriter, r *http.Request, _ map[string]any) {
	group, ok := f.firewalls[r.PathValue("id")]
	if !ok {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	if count, _ := group["instance_count"].(int); count > 0 {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	delete(f.firewalls, r.PathValue("id"))
	w.WriteHeader(http.StatusNoContent)
}

// createFirewallRule stores the rule under the version its subnet belongs to: ip_type
// comes from the subnet's family, and ICMP takes the version's name (the spec: "the
// rule is stored with the version-appropriate name"). A special subnet value such as
// Cloudflare is not an address; it is stored as v4, which the spec leaves open.
func (f *StubOnidelAPI) createFirewallRule(w http.ResponseWriter, r *http.Request, body map[string]any) {
	group, ok := f.firewalls[r.PathValue("id")]
	if !ok {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	// The spec requires protocol, subnet and subnet_size, and lists the protocols.
	protocol, _ := body["protocol"].(string)
	subnet, _ := body["subnet"].(string)
	subnetSize := body["subnet_size"]
	if subnet == "" {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	ipType := "v4"
	if ip := net.ParseIP(subnet); ip != nil && ip.To4() == nil {
		ipType = "v6"
	}
	switch {
	case protocol == "icmp" && ipType == "v6":
		protocol = "ipv6-icmp"
	case protocol == "ipv6-icmp" && ipType == "v4":
		protocol = "icmp"
	}
	port, _ := body["port"].(string)
	desc, _ := body["desc"].(string)
	rule := map[string]any{
		"id": f.claimID(), "group": r.PathValue("id"), "ip_type": ipType, "action": "allow",
		"protocol": protocol, "port": port, "subnet": subnet, "subnet_size": subnetSize, "desc": desc,
	}
	f.rules[rule["id"].(string)] = rule
	count, _ := group["rule_count"].(int)
	group["rule_count"] = count + 1
	// The live API answers a create with subnet_size as a string (checked 2026-10-02).
	created := maps.Clone(rule)
	created["subnet_size"] = fmt.Sprint(subnetSize)
	sendJSON(w, http.StatusCreated, map[string]any{"firewall_rule": created})
}

func (f *StubOnidelAPI) sendFirewallRule(w http.ResponseWriter, r *http.Request, _ map[string]any) {
	rule, ok := f.findRule(r)
	if !ok {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	sendJSON(w, http.StatusOK, map[string]any{"firewall_rule": rule})
}

// findRule finds the path's rule, only within the path's group.
func (f *StubOnidelAPI) findRule(r *http.Request) (map[string]any, bool) {
	rule, ok := f.rules[r.PathValue("rule")]
	if !ok || rule["group"] != r.PathValue("id") {
		return nil, false
	}
	return rule, true
}

// updateFirewallRule changes the description, the only field the spec lets a PATCH
// change; the spec requires desc and caps it at 255 characters.
func (f *StubOnidelAPI) updateFirewallRule(w http.ResponseWriter, r *http.Request, body map[string]any) {
	desc, _ := body["desc"].(string)
	rule, ok := f.findRule(r)
	if !ok {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	rule["desc"] = desc
	w.WriteHeader(http.StatusOK)
}

func (f *StubOnidelAPI) removeFirewallRule(w http.ResponseWriter, r *http.Request, _ map[string]any) {
	rule, ok := f.findRule(r)
	if !ok {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	delete(f.rules, r.PathValue("rule"))
	if group, ok := f.firewalls[rule["group"].(string)]; ok {
		count, _ := group["rule_count"].(int)
		group["rule_count"] = count - 1
	}
	w.WriteHeader(http.StatusNoContent)
}
