package onideltest

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"maps"
	"net"
	"net/http"
	"net/http/httptest"
	"slices"
	"sync"
	"testing"
)

// TeamID is the one team the fake API starts with, as GET /teams lists it.
const TeamID = "169b0175-361a-4ea7-b31f-d82f42bc43b1"

// APIKey is the bearer token the fake API accepts. Any other token gets a 401.
const APIKey = "test-key"

// FakeAPI is an in-memory Onidel API, written against provider/spec/onidel.yaml and
// shaped after live responses: GET /vm returns a bare array, a VM object carries the
// root password in plain text, a missing VM is a 404 with an empty body, and POST /vm
// is a 201 with no body.
//
// A VM settles on the first read of GET /vm/{id} after it changes: that read reports
// the in-flight state (status building, or an active_action_id), and the next read
// sees it active with no action. SetAutoSettle(false) holds every VM where it is.
//
// The fake records every request. A request no route serves, or a body that is not
// JSON, is a problem: it gets a 500 or a 400 and is listed by GetProblems.
type FakeAPI struct {
	// URL is the base URL of the running fake.
	URL string

	mu         sync.Mutex
	seq        int
	autoSettle bool
	teams      []map[string]any
	sshKeys    map[string]map[string]any
	vms        map[string]map[string]any
	vmOrder    []string
	firewalls  map[string]map[string]any
	rules      map[string]map[string]any
	rdns       map[string]map[string]string // VM ID -> IP -> domain
	requests   []Request
	problems   []string

	routes    *http.ServeMux
	overrides *http.ServeMux
}

// StartFakeAPI starts a fake API with one team and no resources. The server stops
// when the test ends.
func StartFakeAPI(t testing.TB) *FakeAPI {
	t.Helper()
	f := &FakeAPI{
		autoSettle: true,
		teams:      []map[string]any{{"id": TeamID, "name": "team", "role": "Team Owner"}},
		sshKeys:    map[string]map[string]any{},
		vms:        map[string]map[string]any{},
		firewalls:  map[string]map[string]any{},
		rules:      map[string]map[string]any{},
		rdns:       map[string]map[string]string{},
		routes:     http.NewServeMux(),
		overrides:  http.NewServeMux(),
	}
	f.registerRoutes()
	server := httptest.NewServer(f)
	t.Cleanup(server.Close)
	f.URL = server.URL
	return f
}

// RegisterHandler serves pattern (a net/http ServeMux pattern such as "POST /vm") with
// h instead of the fake's own route, so a test can stand in for one deviation: an
// error status or an undocumented payload. h runs without the fake's lock, so it may
// call the fake's setters.
func (f *FakeAPI) RegisterHandler(pattern string, h http.HandlerFunc) {
	f.overrides.HandleFunc(pattern, h)
}

// SetAutoSettle chooses whether VMs settle on read (the default) or hold their
// in-flight state.
func (f *FakeAPI) SetAutoSettle(enabled bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.autoSettle = enabled
}

// SetTeams replaces the teams GET /teams lists.
func (f *FakeAPI) SetTeams(teams ...map[string]any) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.teams = teams
}

// SetVM stores vm under its "id", replacing any VM with that ID.
func (f *FakeAPI) SetVM(vm map[string]any) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.setVM(maps.Clone(vm))
}

// SetFirewallGroup stores group under its "id", replacing any group with that ID.
func (f *FakeAPI) SetFirewallGroup(group map[string]any) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.firewalls[group["id"].(string)] = maps.Clone(group)
}

// GetRequests returns every request received so far, in order.
func (f *FakeAPI) GetRequests() []Request {
	f.mu.Lock()
	defer f.mu.Unlock()
	return slices.Clone(f.requests)
}

// GetProblems lists the unhandled requests and undecodable bodies seen so far.
func (f *FakeAPI) GetProblems() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return slices.Clone(f.problems)
}

// GetSSHKeys returns the stored SSH keys by ID.
func (f *FakeAPI) GetSSHKeys() map[string]map[string]any {
	f.mu.Lock()
	defer f.mu.Unlock()
	return buildStoreCopy(f.sshKeys)
}

// GetVMs returns the stored VMs by ID.
func (f *FakeAPI) GetVMs() map[string]map[string]any {
	f.mu.Lock()
	defer f.mu.Unlock()
	return buildStoreCopy(f.vms)
}

// GetFirewallGroups returns the stored firewall groups by ID.
func (f *FakeAPI) GetFirewallGroups() map[string]map[string]any {
	f.mu.Lock()
	defer f.mu.Unlock()
	return buildStoreCopy(f.firewalls)
}

// GetFirewallRules returns the stored firewall rules by ID.
func (f *FakeAPI) GetFirewallRules() map[string]map[string]any {
	f.mu.Lock()
	defer f.mu.Unlock()
	return buildStoreCopy(f.rules)
}

// GetRDNS returns the stored PTR records as VM ID -> IP -> domain.
func (f *FakeAPI) GetRDNS() map[string]map[string]string {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := make(map[string]map[string]string, len(f.rdns))
	for vmID, records := range f.rdns {
		out[vmID] = maps.Clone(records)
	}
	return out
}

// ServeHTTP records the request, then answers it: 400 for a body that is not a JSON
// object, 401 for a wrong bearer token, else the registered override or the route.
func (f *FakeAPI) ServeHTTP(w http.ResponseWriter, r *http.Request) {
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
	if r.Header.Get("Authorization") != "Bearer "+APIKey {
		w.WriteHeader(http.StatusUnauthorized)
		return
	}
	r.Body = io.NopCloser(bytes.NewReader(raw))
	if h, pattern := f.overrides.Handler(r); pattern != "" {
		h.ServeHTTP(w, r)
		return
	}
	f.routes.ServeHTTP(w, r)
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

func (f *FakeAPI) registerRoutes() {
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
	route("GET /teams", f.readTeams)
	route("GET /os_templates", f.readOSTemplates)

	route("POST /ssh_keys", f.createSSHKey)
	route("GET /ssh_keys/{id}", f.readSSHKey)
	route("PATCH /ssh_keys/{id}", f.updateSSHKey)
	route("DELETE /ssh_keys/{id}", f.removeSSHKey)

	route("GET /vm", f.readVMs)
	route("POST /vm", f.createVM)
	route("GET /vm/{id}", f.readVM)
	route("PATCH /vm/{id}", f.updateVM)
	route("DELETE /vm/{id}", f.removeVM)

	route("POST /network/firewalls", f.createFirewallGroup)
	route("GET /network/firewalls/{id}", f.readFirewallGroup)
	route("PUT /network/firewalls/{id}", f.updateFirewallGroup)
	route("DELETE /network/firewalls/{id}", f.removeFirewallGroup)

	route("POST /network/firewalls/{id}/rules", f.createFirewallRule)
	route("GET /network/firewalls/{id}/rules/{rule}", f.readFirewallRule)
	route("PATCH /network/firewalls/{id}/rules/{rule}", f.updateFirewallRule)
	route("DELETE /network/firewalls/{id}/rules/{rule}", f.removeFirewallRule)

	route("GET /vm/{id}/rdns", f.readRDNS)
	route("POST /vm/{id}/rdns", f.updateRDNS)
	route("DELETE /vm/{id}/rdns/{ip}", f.removeRDNS)
}

func (f *FakeAPI) checkUnhandled(w http.ResponseWriter, r *http.Request, _ map[string]any) {
	target := r.URL.Path
	if r.URL.RawQuery != "" {
		target += "?" + r.URL.RawQuery
	}
	f.problems = append(f.problems, fmt.Sprintf("unhandled request: %s %s", r.Method, target))
	w.WriteHeader(http.StatusInternalServerError)
}

func (f *FakeAPI) readTeams(w http.ResponseWriter, _ *http.Request, _ map[string]any) {
	sendJSON(w, http.StatusOK, f.teams)
}

func (f *FakeAPI) readOSTemplates(w http.ResponseWriter, _ *http.Request, _ map[string]any) {
	sendJSON(w, http.StatusOK, []any{
		map[string]any{"id": 3, "name": "Ubuntu 24.04 LTS x64", "family": "Ubuntu"},
		map[string]any{"id": 24, "name": "Ubuntu 26.04 LTS x64", "family": "Ubuntu"},
	})
}

// NewSSHKey and UpdateSSHKey both require team_id, name and ssh_key.
func (f *FakeAPI) createSSHKey(w http.ResponseWriter, _ *http.Request, body map[string]any) {
	if !hasStrings(body, "team_id", "name", "ssh_key") {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	key := map[string]any{
		"id": f.claimID(), "created": "2026-10-02T05:35:28Z", "name": body["name"], "ssh_key": body["ssh_key"],
	}
	f.sshKeys[key["id"].(string)] = key
	sendJSON(w, http.StatusCreated, map[string]any{"ssh_key": key})
}

func (f *FakeAPI) readSSHKey(w http.ResponseWriter, r *http.Request, _ map[string]any) {
	key, ok := f.sshKeys[r.PathValue("id")]
	if !ok {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	sendJSON(w, http.StatusOK, map[string]any{"ssh_key": key})
}

func (f *FakeAPI) updateSSHKey(w http.ResponseWriter, r *http.Request, body map[string]any) {
	if !hasStrings(body, "team_id", "name", "ssh_key") {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	key, ok := f.sshKeys[r.PathValue("id")]
	if !ok {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	key["name"], key["ssh_key"] = body["name"], body["ssh_key"]
	w.WriteHeader(http.StatusNoContent)
}

func (f *FakeAPI) removeSSHKey(w http.ResponseWriter, r *http.Request, _ map[string]any) {
	if _, ok := f.sshKeys[r.PathValue("id")]; !ok {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	delete(f.sshKeys, r.PathValue("id"))
	w.WriteHeader(http.StatusNoContent)
}

// readVMs lists VMs in the order they were stored.
func (f *FakeAPI) readVMs(w http.ResponseWriter, _ *http.Request, _ map[string]any) {
	list := []any{}
	for _, id := range f.vmOrder {
		list = append(list, f.vms[id])
	}
	sendJSON(w, http.StatusOK, list)
}

// createVM provisions a VM in status building. NewVM documents "provide one of os,
// snapshot_id or iso_id", so any other count is a 400.
func (f *FakeAPI) createVM(w http.ResponseWriter, _ *http.Request, body map[string]any) {
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

func (f *FakeAPI) readVM(w http.ResponseWriter, r *http.Request, _ map[string]any) {
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

// The statuses the client treats as settling into active on their own.
var settlingStatuses = []string{"building", "restoring", "migrating", "taking_snaphot"}

func isSettling(vm map[string]any) bool {
	status, _ := vm["status"].(string)
	return slices.Contains(settlingStatuses, status) || vm["active_action_id"] != nil
}

// updateVM applies one setting per request (202), refuses a VM with an action in
// flight (409), and starts an action that the next read settles.
func (f *FakeAPI) updateVM(w http.ResponseWriter, r *http.Request, body map[string]any) {
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
			w.WriteHeader(http.StatusBadRequest)
			return
		}
	}
	vm["active_action_id"] = 42
	w.WriteHeader(http.StatusAccepted)
}

func (f *FakeAPI) removeVM(w http.ResponseWriter, r *http.Request, _ map[string]any) {
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

// createFirewallGroup needs a description (the spec) and a team_id: the live API
// answers 401, not 400, when team_id is missing (checked 2026-10-02).
func (f *FakeAPI) createFirewallGroup(w http.ResponseWriter, _ *http.Request, body map[string]any) {
	if !hasStrings(body, "team_id") {
		sendJSON(w, http.StatusUnauthorized, map[string]any{"err": "UNAUTHORIZED"})
		return
	}
	if _, ok := body["description"].(string); !ok {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	group := map[string]any{
		"id": f.claimID(), "description": body["description"], "created": "2026-10-02T00:00:00Z",
		"updated": "2026-10-02T00:00:00Z", "instance_count": 0, "rule_count": 0,
	}
	f.firewalls[group["id"].(string)] = group
	sendJSON(w, http.StatusCreated, map[string]any{"firewall_group": group})
}

func (f *FakeAPI) readFirewallGroup(w http.ResponseWriter, r *http.Request, _ map[string]any) {
	group, ok := f.firewalls[r.PathValue("id")]
	if !ok {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	sendJSON(w, http.StatusOK, map[string]any{"firewall_group": group})
}

func (f *FakeAPI) updateFirewallGroup(w http.ResponseWriter, r *http.Request, body map[string]any) {
	if _, ok := body["description"].(string); !ok {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
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
func (f *FakeAPI) removeFirewallGroup(w http.ResponseWriter, r *http.Request, _ map[string]any) {
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
func (f *FakeAPI) createFirewallRule(w http.ResponseWriter, r *http.Request, body map[string]any) {
	group, ok := f.firewalls[r.PathValue("id")]
	if !ok {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	protocol, _ := body["protocol"].(string)
	subnet, _ := body["subnet"].(string)
	subnetSize, hasSize := body["subnet_size"]
	if !slices.Contains([]string{"tcp", "udp", "icmp", "ipv6-icmp"}, protocol) || subnet == "" || !hasSize {
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

func (f *FakeAPI) readFirewallRule(w http.ResponseWriter, r *http.Request, _ map[string]any) {
	rule, ok := f.findRule(r)
	if !ok {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	sendJSON(w, http.StatusOK, map[string]any{"firewall_rule": rule})
}

// findRule finds the path's rule, only within the path's group.
func (f *FakeAPI) findRule(r *http.Request) (map[string]any, bool) {
	rule, ok := f.rules[r.PathValue("rule")]
	if !ok || rule["group"] != r.PathValue("id") {
		return nil, false
	}
	return rule, true
}

// updateFirewallRule changes the description, the only field the spec lets a PATCH
// change; desc is required and at most 255 characters.
func (f *FakeAPI) updateFirewallRule(w http.ResponseWriter, r *http.Request, body map[string]any) {
	desc, ok := body["desc"].(string)
	if !ok || len(desc) > 255 {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	rule, ok := f.findRule(r)
	if !ok {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	rule["desc"] = desc
	w.WriteHeader(http.StatusOK)
}

func (f *FakeAPI) removeFirewallRule(w http.ResponseWriter, r *http.Request, _ map[string]any) {
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

// readRDNS lists a VM's PTR records sorted by IP. A VM with none, or an unknown VM,
// lists none: the spec documents no 404 here.
func (f *FakeAPI) readRDNS(w http.ResponseWriter, r *http.Request, _ map[string]any) {
	records := f.rdns[r.PathValue("id")]
	list := []any{}
	for _, ip := range slices.Sorted(maps.Keys(records)) {
		list = append(list, map[string]any{"ip": ip, "domain": records[ip]})
	}
	sendJSON(w, http.StatusOK, map[string]any{"rdns": list})
}

// updateRDNS sets a PTR record: 400 for a missing or invalid IP or domain, 401 when
// the IP is not the VM's (the spec's "IP not owned by this VM").
func (f *FakeAPI) updateRDNS(w http.ResponseWriter, r *http.Request, body map[string]any) {
	ip, _ := body["ip_addr"].(string)
	domain, _ := body["domain"].(string)
	if net.ParseIP(ip) == nil || domain == "" {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	if !f.isVMAddress(r.PathValue("id"), ip) {
		w.WriteHeader(http.StatusUnauthorized)
		return
	}
	if f.rdns[r.PathValue("id")] == nil {
		f.rdns[r.PathValue("id")] = map[string]string{}
	}
	f.rdns[r.PathValue("id")][ip] = domain
	w.WriteHeader(http.StatusOK)
}

func (f *FakeAPI) removeRDNS(w http.ResponseWriter, r *http.Request, _ map[string]any) {
	ip := r.PathValue("ip")
	if net.ParseIP(ip) == nil {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	if !f.isVMAddress(r.PathValue("id"), ip) {
		w.WriteHeader(http.StatusUnauthorized)
		return
	}
	delete(f.rdns[r.PathValue("id")], ip)
	w.WriteHeader(http.StatusNoContent)
}

func (f *FakeAPI) isVMAddress(vmID, ip string) bool {
	vm, ok := f.vms[vmID]
	if !ok {
		return false
	}
	want := net.ParseIP(ip)
	for _, key := range []string{"main_ipv4", "main_ipv6"} {
		address, _ := vm[key].(string)
		if got := net.ParseIP(address); got != nil && got.Equal(want) {
			return true
		}
	}
	return false
}

func (f *FakeAPI) setVM(vm map[string]any) {
	id := vm["id"].(string)
	if _, ok := f.vms[id]; !ok {
		f.vmOrder = append(f.vmOrder, id)
	}
	f.vms[id] = vm
}

// updateInstanceCount moves a group's instance_count when a VM attaches or detaches.
// A VM may report its group by a numeric ID no stored group has; that changes nothing.
func (f *FakeAPI) updateInstanceCount(groupID any, delta int) {
	id, _ := groupID.(string)
	group, ok := f.firewalls[id]
	if !ok {
		return
	}
	count, _ := group["instance_count"].(int)
	group["instance_count"] = count + delta
}

func (f *FakeAPI) claimID() string {
	f.seq++
	return fmt.Sprintf("00000000-0000-4000-8000-%012d", f.seq)
}

func hasStrings(body map[string]any, keys ...string) bool {
	for _, key := range keys {
		if s, _ := body[key].(string); s == "" {
			return false
		}
	}
	return true
}

func buildStoreCopy(store map[string]map[string]any) map[string]map[string]any {
	out := make(map[string]map[string]any, len(store))
	for id, item := range store {
		out[id] = maps.Clone(item)
	}
	return out
}

func sendJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}
