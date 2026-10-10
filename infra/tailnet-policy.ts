// The whole tailnet policy file. Pulumi's tailscale.Acl replaces the live file
// with this one, so every rule the tailnet relies on must be here.
//
// home-pc (the WSL node, home-wsl), where atc's daemon listens on its tailnet address.
const homePC = {
  ip: '100.67.122.120',
  daemonPort: 8415,
};

// imp's own tailnet node on geoffcloud (imp-geoffcloud, tag:imp), where impd serves
// https://imps.geoff.cloud. A long-lived node, so its address is stable; a host alias
// names this one node, where tag:imp would also take in any later impd node.
const impNode = {
  ip: '100.75.9.119',
  httpsPort: 443,
};

// Tags:
// - tag:cloud — cloud hosts and their egress (cloudflared, the atc gateway). It reaches
//   only the PC's atc daemon port, for the gateway, and imp's node on 443 only, for the
//   health probe.
// - tag:imp — impd nodes. Members reach them on any port (one port per imp);
//   they reach nothing, which is imp's isolation goal.
// - tag:imp-e2e — the throwaway impd nodes of imp's e2e suites. They reach only each
//   other's API, never a tag:imp node, so a test run cannot touch a live impd. Their
//   keys come from an OAuth client of their own (auth_keys scope, this tag only),
//   kept in imp's own 1Password vault (docs/runbooks/imp-e2e-tailnet.md).
export const tailnetPolicy = {
  hosts: {
    'home-pc': homePC.ip,
    'imp-geoffcloud': impNode.ip,
  },

  // Each tag also owns itself: Pulumi's OAuth client carries tag:cloud and tag:imp,
  // and a client may mint keys only for tags its own tags own.
  tagOwners: {
    'tag:cloud': ['autogroup:admin', 'tag:cloud'],
    'tag:imp': ['autogroup:admin', 'tag:imp'],

    // owns itself, so the e2e OAuth client (tag:imp-e2e) may mint keys for it; no
    // other tag owns it, and it owns no other tag
    'tag:imp-e2e': ['autogroup:admin', 'tag:imp-e2e'],
  },
  grants: [
    // members reach every device; tagged nodes get only what a grant gives them
    { src: ['autogroup:member'], dst: ['*'], ip: ['*'] },

    // impd nodes reach each other's API: moves between hosts and imp's two-node e2e
    { src: ['tag:imp'], dst: ['tag:imp'], ip: ['tcp:7070'] },

    // the atc gateway on a cloud host → atc's daemon on the PC; last, so adding it
    // shifts no other grant
    { src: ['tag:cloud'], dst: ['home-pc'], ip: [`tcp:${homePC.daemonPort}`] },

    // the cluster's probe of imp's /health (#29) → imp's node, 443 only; last, so
    // adding it shifts no other grant
    { src: ['tag:cloud'], dst: ['imp-geoffcloud'], ip: [`tcp:${impNode.httpsPort}`] },

    // imp's e2e nodes reach each other's API only, for the two-node moves suite; no
    // grant takes them to tag:imp. Last, so adding it shifts no other grant
    { src: ['tag:imp-e2e'], dst: ['tag:imp-e2e'], ip: ['tcp:7070'] },
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
