// The whole tailnet policy file. Pulumi's tailscale.Acl replaces the live file
// with this one, so every rule the tailnet relies on must be here.
//
// Tags:
// - tag:cloud — cloud hosts and their egress (cloudflared). No grants yet; the
//   ingress route to Geoff's PC lands with #7.
// - tag:imp — impd nodes. Members reach them on any port (one port per imp);
//   they reach nothing, which is imp's isolation goal.
export const tailnetPolicy = {
  tagOwners: {
    'tag:cloud': ['autogroup:admin'],
    'tag:imp': ['autogroup:admin'],
  },
  grants: [
    // members reach every device; tagged nodes get only what a grant gives them
    { src: ['autogroup:member'], dst: ['*'], ip: ['*'] },
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
