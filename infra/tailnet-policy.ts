// The whole tailnet policy file. Pulumi's tailscale.Acl replaces the live file
// with this one, so every rule the tailnet relies on must be here.
//
// Geoff's PC (the WSL node), where atc's MCP listens behind `tailscale serve` on 443.
export const homePC = {
  dnsName: 'home-wsl.tailfa02d3.ts.net',
  ip: '100.67.122.120',
};

// Tags:
// - tag:cloud — cloud hosts and their egress (cloudflared). It reaches only the
//   PC's `tailscale serve` port, for the mcp.geoff.cloud route (#7).
// - tag:imp — impd nodes. Members reach them on any port (one port per imp);
//   they reach nothing, which is imp's isolation goal.
export const tailnetPolicy = {
  hosts: {
    'home-pc': homePC.ip,
  },
  tagOwners: {
    'tag:cloud': ['autogroup:admin'],
    'tag:imp': ['autogroup:admin'],
  },
  grants: [
    // members reach every device; tagged nodes get only what a grant gives them
    { src: ['autogroup:member'], dst: ['*'], ip: ['*'] },

    // cloudflared on a cloud host → atc's MCP on the PC
    { src: ['tag:cloud'], dst: ['home-pc'], ip: ['tcp:443'] },
  ],
  ssh: [
    {
      action: 'check',
      src: ['autogroup:member'],
      dst: ['autogroup:self'],
      users: ['autogroup:nonroot', 'root'],
    },

    // tailnet SSH to cloud hosts, admins only
    {
      action: 'check',
      src: ['autogroup:admin'],
      dst: ['tag:cloud'],
      users: ['autogroup:nonroot', 'root'],
    },
  ],
  nodeAttrs: [{ target: ['autogroup:member'], attr: ['funnel'] }],
};
