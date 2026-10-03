// The whole tailnet policy file. Pulumi's tailscale.Acl replaces the live file
// with this one, so every rule the tailnet relies on must be here.
//
// Geoff's PC (the WSL node, home-wsl), where atc's MCP listens on its tailnet address.
export const homePC = {
  ip: '100.67.122.120',
  mcpPort: 8414,
};

// Tags:
// - tag:cloud — cloud hosts and their egress (cloudflared). It reaches only the
//   PC's atc MCP port, for the mcp.geoff.cloud route (#7).
// - tag:imp — impd nodes. Members reach them on any port (one port per imp);
//   they reach nothing, which is imp's isolation goal.
// - tag:ci — ephemeral GitHub Actions runners (the drift workflow). They reach only
//   the k3s API on cloud hosts, so a refresh can read the cluster.
export const tailnetPolicy = {
  hosts: {
    'home-pc': homePC.ip,
  },

  // Each tag also owns itself: Pulumi's OAuth client carries tag:cloud and tag:imp,
  // and a client may mint keys only for tags its own tags own.
  tagOwners: {
    'tag:cloud': ['autogroup:admin', 'tag:cloud'],
    'tag:imp': ['autogroup:admin', 'tag:imp'],
    'tag:ci': ['autogroup:admin'],
  },
  grants: [
    // members reach every device; tagged nodes get only what a grant gives them
    { src: ['autogroup:member'], dst: ['*'], ip: ['*'] },

    // cloudflared on a cloud host → atc's MCP on the PC
    { src: ['tag:cloud'], dst: ['home-pc'], ip: [`tcp:${homePC.mcpPort}`] },

    // impd nodes reach each other's API: moves between hosts and imp's two-node e2e
    { src: ['tag:imp'], dst: ['tag:imp'], ip: ['tcp:7070'] },

    // the drift workflow's runner → the k3s API, for a refresh preview
    { src: ['tag:ci'], dst: ['tag:cloud'], ip: ['tcp:6443'] },
  ],
  ssh: [
    {
      action: 'check',
      src: ['autogroup:member'],
      dst: ['autogroup:self'],
      users: ['autogroup:nonroot', 'root'],
    },

    // tailnet SSH to cloud hosts, admins only. accept, not check: scripts and agents
    // SSH unattended, and check mode asks for a browser login every 12 hours.
    {
      action: 'accept',
      src: ['autogroup:admin'],
      dst: ['tag:cloud'],
      users: ['autogroup:nonroot', 'root'],
    },
  ],
  nodeAttrs: [{ target: ['autogroup:member'], attr: ['funnel'] }],
};
