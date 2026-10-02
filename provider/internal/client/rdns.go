package client

import (
	"context"
	"net/http"
	"net/url"
)

// RDNSRecord is one PTR record on a VM's IP address.
type RDNSRecord struct {
	IP     string `json:"ip"`
	Domain string `json:"domain"`
}

// ReadRDNS lists a VM's PTR records (GET /vm/{vm_id}/rdns).
func (c *Client) ReadRDNS(ctx context.Context, vmID, teamID string) ([]RDNSRecord, error) {
	var out struct {
		RDNS []RDNSRecord `json:"rdns"`
	}
	_, err := c.sendRequest(ctx, http.MethodGet, buildVMPath(vmID)+"/rdns", buildTeamQuery(teamID), nil, &out)
	return out.RDNS, err
}

// UpdateRDNS sets the PTR record for one of the VM's IPs (POST /vm/{vm_id}/rdns). The
// domain must already resolve to the IP. Setting it again overwrites it.
func (c *Client) UpdateRDNS(ctx context.Context, vmID, teamID, ip, domain string) error {
	body := struct {
		TeamID string `json:"team_id,omitempty"`
		IPAddr string `json:"ip_addr"`
		Domain string `json:"domain"`
	}{teamID, ip, domain}
	_, err := c.sendRequest(ctx, http.MethodPost, buildVMPath(vmID)+"/rdns", nil, body, nil)
	return err
}

// RemoveRDNS deletes the PTR record for one IP (DELETE /vm/{vm_id}/rdns/{ip_addr}).
func (c *Client) RemoveRDNS(ctx context.Context, vmID, teamID, ip string) error {
	_, err := c.sendRequest(ctx, http.MethodDelete, buildVMPath(vmID)+"/rdns/"+url.PathEscape(ip),
		buildTeamQuery(teamID), nil, nil)
	return err
}
