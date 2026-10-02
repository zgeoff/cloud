package onidel

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
)

// fakeRootPassword stands in for the root password the real API returns in every VM
// object. Tests assert it never reaches provider state.
const fakeRootPassword = "fixture-root-pw-do-not-leak"

const fakeTeamID = "169b0175-361a-4ea7-b31f-d82f42bc43b1"

// fakeAPI is an in-memory Onidel API, shaped after live responses: GET /vm returns a
// bare array, VM objects carry location and password, a missing VM is a 404 with an
// empty body, and POST /vm is a 201 with no body.
type fakeAPI struct {
	t   *testing.T
	mu  sync.Mutex
	seq int

	sshKeys   map[string]map[string]any
	vms       map[string]map[string]any
	firewalls map[string]map[string]any
	rules     map[string]map[string]any
	rdns      map[string]map[string]string // vm ID -> ip -> domain

	// requests records "METHOD path" plus the decoded body, in order.
	requests []fakeRequest
}

type fakeRequest struct {
	Method string
	Path   string
	Body   map[string]any
}

func newFakeAPI(t *testing.T) (*fakeAPI, *httptest.Server) {
	t.Helper()
	f := &fakeAPI{
		t:         t,
		sshKeys:   map[string]map[string]any{},
		vms:       map[string]map[string]any{},
		firewalls: map[string]map[string]any{},
		rules:     map[string]map[string]any{},
		rdns:      map[string]map[string]string{},
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /teams", f.withLock(func(w http.ResponseWriter, _ *http.Request) {
		writeFakeJSON(w, 200, []any{map[string]any{"id": fakeTeamID, "name": "team", "role": "Team Owner"}})
	}))
	mux.HandleFunc("GET /os_templates", f.withLock(func(w http.ResponseWriter, _ *http.Request) {
		writeFakeJSON(w, 200, []any{
			map[string]any{"id": 3, "name": "Ubuntu 24.04 LTS x64", "family": "Ubuntu"},
			map[string]any{"id": 24, "name": "Ubuntu 26.04 LTS x64", "family": "Ubuntu"},
		})
	}))

	mux.HandleFunc("POST /ssh_keys", f.withLock(func(w http.ResponseWriter, r *http.Request) {
		body := f.record(r)
		if body["team_id"] == nil || body["team_id"] == "" {
			writeFakeJSON(w, 400, map[string]any{"err": "MISSING_TEAM_ID"})
			return
		}
		key := map[string]any{"id": f.nextID(), "created": "2026-10-02T05:35:28Z", "name": body["name"], "ssh_key": body["ssh_key"]}
		f.sshKeys[key["id"].(string)] = key
		writeFakeJSON(w, 201, map[string]any{"ssh_key": key})
	}))
	mux.HandleFunc("GET /ssh_keys/{id}", f.withLock(func(w http.ResponseWriter, r *http.Request) {
		f.record(r)
		key, ok := f.sshKeys[r.PathValue("id")]
		if !ok {
			w.WriteHeader(404)
			return
		}
		writeFakeJSON(w, 200, map[string]any{"ssh_key": key})
	}))
	mux.HandleFunc("PATCH /ssh_keys/{id}", f.withLock(func(w http.ResponseWriter, r *http.Request) {
		body := f.record(r)
		key, ok := f.sshKeys[r.PathValue("id")]
		if !ok {
			w.WriteHeader(404)
			return
		}
		key["name"], key["ssh_key"] = body["name"], body["ssh_key"]
		w.WriteHeader(204)
	}))
	mux.HandleFunc("DELETE /ssh_keys/{id}", f.withLock(f.removeFrom(func() map[string]map[string]any { return f.sshKeys })))

	mux.HandleFunc("GET /vm", f.withLock(func(w http.ResponseWriter, r *http.Request) {
		f.record(r)
		list := []any{}
		for _, vm := range f.vms {
			list = append(list, vm)
		}
		writeFakeJSON(w, 200, list)
	}))
	mux.HandleFunc("POST /vm", f.withLock(func(w http.ResponseWriter, r *http.Request) {
		body := f.record(r)
		id := f.nextID()
		var firewall any
		if fw, ok := body["firewall_group_id"]; ok {
			firewall = fw
		}
		ipv6 := ""
		if body["ipv6"] == true {
			ipv6 = "2401:db8::1"
		}
		f.vms[id] = map[string]any{
			"id": id, "name": body["name"], "vcpu": body["cpu"], "ram": body["ram"], "disk": body["disk"],
			"location": body["location"], "password": fakeRootPassword, "main_ipv4": "203.0.113.10",
			"main_ipv6": ipv6, "template": "Ubuntu 26.04 LTS x64", "firewall_group_id": firewall,
			"created_at": "2026-10-02T05:48:53Z", "status": "building", "active_action_id": nil,
			"bgp_enabled": false,
		}
		w.WriteHeader(201)
	}))
	mux.HandleFunc("GET /vm/{id}", f.withLock(func(w http.ResponseWriter, r *http.Request) {
		f.record(r)
		vm, ok := f.vms[r.PathValue("id")]
		if !ok {
			w.WriteHeader(404)
			return
		}
		writeFakeJSON(w, 200, vm)
		// Async work finishes after one observation.
		vm["status"] = "active"
		vm["active_action_id"] = nil
	}))
	mux.HandleFunc("PATCH /vm/{id}", f.withLock(func(w http.ResponseWriter, r *http.Request) {
		body := f.record(r)
		vm, ok := f.vms[r.PathValue("id")]
		if !ok {
			w.WriteHeader(404)
			return
		}
		if vm["active_action_id"] != nil {
			w.WriteHeader(409)
			return
		}
		settings := 0
		for k, v := range body {
			switch k {
			case "team_id":
				continue
			case "name":
				vm["name"] = v
			case "enable_ipv6":
				vm["main_ipv6"] = map[bool]string{true: "2401:db8::1", false: ""}[v == true]
			case "firewall_group_id":
				vm["firewall_group_id"] = v
			case "disable_firewall":
				vm["firewall_group_id"] = nil
			}
			settings++
		}
		if settings != 1 {
			writeFakeJSON(w, 400, map[string]any{"err": "ONE_SETTING_PER_REQUEST"})
			return
		}
		vm["active_action_id"] = 42
		w.WriteHeader(202)
	}))
	mux.HandleFunc("DELETE /vm/{id}", f.withLock(f.removeFrom(func() map[string]map[string]any { return f.vms })))

	mux.HandleFunc("POST /network/firewalls", f.withLock(func(w http.ResponseWriter, r *http.Request) {
		body := f.record(r)
		group := map[string]any{
			"id": f.nextID(), "description": body["description"], "created": "2026-10-02T00:00:00Z",
			"updated": "2026-10-02T00:00:00Z", "instance_count": 0, "rule_count": 0,
		}
		f.firewalls[group["id"].(string)] = group
		writeFakeJSON(w, 201, map[string]any{"firewall_group": group})
	}))
	mux.HandleFunc("GET /network/firewalls/{id}", f.withLock(func(w http.ResponseWriter, r *http.Request) {
		f.record(r)
		group, ok := f.firewalls[r.PathValue("id")]
		if !ok {
			w.WriteHeader(404)
			return
		}
		writeFakeJSON(w, 200, map[string]any{"firewall_group": group})
	}))
	mux.HandleFunc("PUT /network/firewalls/{id}", f.withLock(func(w http.ResponseWriter, r *http.Request) {
		body := f.record(r)
		group, ok := f.firewalls[r.PathValue("id")]
		if !ok {
			w.WriteHeader(404)
			return
		}
		group["description"] = body["description"]
		group["updated"] = "2026-10-03T00:00:00Z"
		w.WriteHeader(204)
	}))
	mux.HandleFunc("DELETE /network/firewalls/{id}", f.withLock(f.removeFrom(func() map[string]map[string]any { return f.firewalls })))

	mux.HandleFunc("POST /network/firewalls/{id}/rules", f.withLock(func(w http.ResponseWriter, r *http.Request) {
		body := f.record(r)
		if _, ok := f.firewalls[r.PathValue("id")]; !ok {
			w.WriteHeader(404)
			return
		}
		protocol := body["protocol"]
		if protocol == "icmp" && body["subnet"] == "::" {
			protocol = "ipv6-icmp"
		}
		port := body["port"]
		if port == nil {
			port = ""
		}
		rule := map[string]any{
			"id": f.nextID(), "group": r.PathValue("id"), "ip_type": "v4", "action": "allow",
			"protocol": protocol, "port": port, "subnet": body["subnet"], "subnet_size": body["subnet_size"],
			"desc": body["desc"],
		}
		f.rules[rule["id"].(string)] = rule
		writeFakeJSON(w, 201, map[string]any{"firewall_rule": rule})
	}))
	mux.HandleFunc("GET /network/firewalls/{id}/rules/{rule}", f.withLock(func(w http.ResponseWriter, r *http.Request) {
		f.record(r)
		rule, ok := f.rules[r.PathValue("rule")]
		if !ok || rule["group"] != r.PathValue("id") {
			w.WriteHeader(404)
			return
		}
		writeFakeJSON(w, 200, map[string]any{"firewall_rule": rule})
	}))
	mux.HandleFunc("PATCH /network/firewalls/{id}/rules/{rule}", f.withLock(func(w http.ResponseWriter, r *http.Request) {
		body := f.record(r)
		rule, ok := f.rules[r.PathValue("rule")]
		if !ok {
			w.WriteHeader(404)
			return
		}
		rule["desc"] = body["desc"]
		w.WriteHeader(200)
	}))
	mux.HandleFunc("DELETE /network/firewalls/{id}/rules/{rule}", f.withLock(func(w http.ResponseWriter, r *http.Request) {
		f.record(r)
		if _, ok := f.rules[r.PathValue("rule")]; !ok {
			w.WriteHeader(404)
			return
		}
		delete(f.rules, r.PathValue("rule"))
		w.WriteHeader(204)
	}))

	mux.HandleFunc("GET /vm/{id}/rdns", f.withLock(func(w http.ResponseWriter, r *http.Request) {
		f.record(r)
		list := []any{}
		for ip, domain := range f.rdns[r.PathValue("id")] {
			list = append(list, map[string]any{"ip": ip, "domain": domain})
		}
		writeFakeJSON(w, 200, map[string]any{"rdns": list})
	}))
	mux.HandleFunc("POST /vm/{id}/rdns", f.withLock(func(w http.ResponseWriter, r *http.Request) {
		body := f.record(r)
		if f.rdns[r.PathValue("id")] == nil {
			f.rdns[r.PathValue("id")] = map[string]string{}
		}
		f.rdns[r.PathValue("id")][body["ip_addr"].(string)] = body["domain"].(string)
		w.WriteHeader(200)
	}))
	mux.HandleFunc("DELETE /vm/{id}/rdns/{ip}", f.withLock(func(w http.ResponseWriter, r *http.Request) {
		f.record(r)
		delete(f.rdns[r.PathValue("id")], r.PathValue("ip"))
		w.WriteHeader(204)
	}))

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer test-key" {
			w.WriteHeader(401)
			return
		}
		mux.ServeHTTP(w, r)
	}))
	t.Cleanup(server.Close)
	return f, server
}

func (f *fakeAPI) withLock(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		h(w, r)
	}
}

func (f *fakeAPI) removeFrom(store func() map[string]map[string]any) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		f.record(r)
		if _, ok := store()[r.PathValue("id")]; !ok {
			w.WriteHeader(404)
			return
		}
		delete(store(), r.PathValue("id"))
		w.WriteHeader(204)
	}
}

func (f *fakeAPI) record(r *http.Request) map[string]any {
	body := map[string]any{}
	raw, _ := io.ReadAll(r.Body)
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &body); err != nil {
			f.t.Errorf("fake API: bad JSON body on %s %s", r.Method, r.URL.Path)
		}
	}
	f.requests = append(f.requests, fakeRequest{Method: r.Method, Path: r.URL.Path, Body: body})
	return body
}

func (f *fakeAPI) nextID() string {
	f.seq++
	return fmt.Sprintf("00000000-0000-4000-8000-%012d", f.seq)
}

// collectRequests returns the recorded requests matching method.
func (f *fakeAPI) collectRequests(method string) []fakeRequest {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []fakeRequest
	for _, r := range f.requests {
		if r.Method == method {
			out = append(out, r)
		}
	}
	return out
}

func writeFakeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}
