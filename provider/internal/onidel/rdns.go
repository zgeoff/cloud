package onidel

import (
	"context"
	"fmt"
	"net"
	"strings"

	"github.com/pulumi/pulumi-go-provider/infer"

	"github.com/zgeoff/cloud/provider/internal/client"
)

// RDNS is onidel:index:Rdns, the PTR record for one of a VM's IP addresses. Its ID is
// `<vmId>/<ip>`, which is also the import ID.
type RDNS struct{}

// RDNSArgs are the Rdns inputs. vmId and ip replace; domain updates in place.
type RDNSArgs struct {
	VMID   string `pulumi:"vmId" provider:"replaceOnChanges"`
	IP     string `pulumi:"ip" provider:"replaceOnChanges"`
	Domain string `pulumi:"domain"`
}

// RDNSState is the Rdns state.
type RDNSState struct {
	RDNSArgs
}

// Annotate sets the token and docs.
func (r *RDNS) Annotate(a infer.Annotator) {
	a.SetToken("index", "Rdns")
	a.Describe(r, "Reverse DNS (PTR) for one of a VM's IPs. The domain must already resolve "+
		"(A/AAAA) to the IP. Import with `<vmId>/<ip>`.")
}

// Annotate documents the inputs.
func (a *RDNSArgs) Annotate(an infer.Annotator) {
	an.Describe(&a.VMID, "ID of the VM that owns the IP.")
	an.Describe(&a.IP, "The VM's IPv4 or IPv6 address.")
	an.Describe(&a.Domain, "The domain the PTR record points to.")
}

// Create sets the record.
func (RDNS) Create(ctx context.Context, req infer.CreateRequest[RDNSArgs]) (infer.CreateResponse[RDNSState], error) {
	state := RDNSState{RDNSArgs: req.Inputs}
	if req.DryRun {
		return infer.CreateResponse[RDNSState]{Output: state}, nil
	}
	api, cfg := getClient(ctx)
	if err := api.UpdateRDNS(ctx, req.Inputs.VMID, cfg.teamID, req.Inputs.IP, req.Inputs.Domain); err != nil {
		return infer.CreateResponse[RDNSState]{}, err
	}
	return infer.CreateResponse[RDNSState]{ID: req.Inputs.VMID + "/" + req.Inputs.IP, Output: state}, nil
}

// Read refreshes or imports the record.
func (RDNS) Read(
	ctx context.Context, req infer.ReadRequest[RDNSArgs, RDNSState],
) (infer.ReadResponse[RDNSArgs, RDNSState], error) {
	vmID, ip, err := splitRDNSID(req.ID)
	if err != nil {
		return infer.ReadResponse[RDNSArgs, RDNSState]{}, err
	}
	api, cfg := getClient(ctx)
	records, err := api.ReadRDNS(ctx, vmID, cfg.teamID)
	if client.IsNotFound(err) {
		return infer.ReadResponse[RDNSArgs, RDNSState]{}, nil
	}
	if err != nil {
		return infer.ReadResponse[RDNSArgs, RDNSState]{}, err
	}
	record, ok := findRDNSRecord(records, ip)
	if !ok || record.Domain == "" {
		return infer.ReadResponse[RDNSArgs, RDNSState]{}, nil
	}
	args := RDNSArgs{VMID: vmID, IP: ip, Domain: record.Domain}
	if strings.EqualFold(strings.TrimSuffix(req.Inputs.Domain, "."), strings.TrimSuffix(record.Domain, ".")) {
		args.Domain = req.Inputs.Domain
	}
	return infer.ReadResponse[RDNSArgs, RDNSState]{ID: req.ID, Inputs: args, State: RDNSState{RDNSArgs: args}}, nil
}

// Update points the record at a new domain; POST overwrites.
func (RDNS) Update(
	ctx context.Context, req infer.UpdateRequest[RDNSArgs, RDNSState],
) (infer.UpdateResponse[RDNSState], error) {
	state := RDNSState{RDNSArgs: req.Inputs}
	if req.DryRun {
		return infer.UpdateResponse[RDNSState]{Output: state}, nil
	}
	api, cfg := getClient(ctx)
	if err := api.UpdateRDNS(ctx, req.Inputs.VMID, cfg.teamID, req.Inputs.IP, req.Inputs.Domain); err != nil {
		return infer.UpdateResponse[RDNSState]{}, err
	}
	return infer.UpdateResponse[RDNSState]{Output: state}, nil
}

// Delete removes the record.
func (RDNS) Delete(ctx context.Context, req infer.DeleteRequest[RDNSState]) (infer.DeleteResponse, error) {
	vmID, ip, err := splitRDNSID(req.ID)
	if err != nil {
		return infer.DeleteResponse{}, err
	}
	api, cfg := getClient(ctx)
	err = api.RemoveRDNS(ctx, vmID, cfg.teamID, ip)
	if client.IsNotFound(err) {
		err = nil
	}
	return infer.DeleteResponse{}, err
}

func splitRDNSID(id string) (string, string, error) {
	vmID, ip, ok := strings.Cut(id, "/")
	if !ok || vmID == "" || net.ParseIP(ip) == nil {
		return "", "", fmt.Errorf("onidel: rdns ID %q is not <vmId>/<ip>", id)
	}
	return vmID, ip, nil
}

// findRDNSRecord matches by parsed IP, so `2001:db8::1` and its expanded form agree.
func findRDNSRecord(records []client.RDNSRecord, ip string) (client.RDNSRecord, bool) {
	want := net.ParseIP(ip)
	for _, record := range records {
		if got := net.ParseIP(record.IP); got != nil && got.Equal(want) {
			return record, true
		}
	}
	return client.RDNSRecord{}, false
}
