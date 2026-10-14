import { topology } from '@zgeoff/cloud-topology';
import { geoffcloudNode } from '../shared/geoffcloud-node.ts';

const tags = topology.tailnet.tags;
const impHostname = topology.tailnet.nodes.imp.hostname;

// The whole tailnet policy file: Pulumi's tailscale.Acl replaces the live file with this,
// so every relied-on rule must be here.
// home-pc is the WSL node (home-wsl), where atc's daemon listens on its tailnet address.
const homePC = {
  ip: topology.tailnet.nodes.homePC.address,
  daemonPort: topology.atc.daemonPort,
};

// imp's own tailnet node on geoffcloud (imp-geoffcloud, tag:imp), where impd serves
// https://imps.geoff.cloud. A long-lived node, so its address is stable; a host alias
// names this one node, where tag:imp would also take in any later impd node.
const impNode = {
  ip: topology.tailnet.nodes.imp.address,
  httpsPort: 443,
};

// k3s's API server on geoffcloud, which the prod apply job reaches from its runner and the
// operator's Pulumi runs reach from home-pc
const k3sAPIPort = topology.k3s.apiPort;

// What ip '*' covers (TCP and UDP on every port, ICMP and ICMPv6), less TCP on k3s's API port: a
// grant only adds access, so the members' grant leaves the port out, and the grants that name it
// add it back for each source that needs it. 58 is ICMPv6, which the policy names by number only.
const allButK3sAPI = [
  `tcp:1-${k3sAPIPort - 1}`,
  `tcp:${k3sAPIPort + 1}-65535`,
  'udp:*',
  'icmp:*',
  '58:*',
];

// impd's API, between impd nodes
const impAPIPort = `tcp:${topology.imp.apiPort}`;

// Tags: tag:cloud reaches only the PC's atc daemon port and imp's 443; members reach tag:imp nodes on any port,
// while those reach each other on impd's API port and nothing else (imp's isolation goal). tag:imp-e2e reaches only its
// own API, never a live impd, keyed by its own OAuth client (1Password imp-e2e vault, docs/runbooks/imp-e2e-tailnet.md).
export const tailnetPolicy = {
  hosts: {
    'home-pc': homePC.ip,
    [impHostname]: impNode.ip,
    geoffcloud: geoffcloudNode.ip,
  },

  // Each tag also owns itself: Pulumi's OAuth client carries tag:cloud and tag:imp,
  // and a client may mint keys only for tags its own tags own.
  tagOwners: {
    [tags.cloud]: ['autogroup:admin', tags.cloud],
    [tags.imp]: ['autogroup:admin', tags.imp],

    // owns itself, so the e2e OAuth client (tag:imp-e2e) may mint keys for it; no
    // other tag owns it, and it owns no other tag
    [tags.impE2E]: ['autogroup:admin', tags.impE2E],

    // the prod apply job's runner, an ephemeral node that joins through the deploy workflow's
    // federated identity (tag:cloud-deploy); owns itself, so that identity may mint keys for it
    [tags.cloudDeploy]: ['autogroup:admin', tags.cloudDeploy],
  },
  grants: [
    // members reach every device on every port but k3s's API port; tagged nodes get only what a
    // grant gives them
    { src: ['autogroup:member'], dst: ['*'], ip: allButK3sAPI },

    // impd nodes reach each other's API: moves between hosts and imp's two-node e2e
    { src: [tags.imp], dst: [tags.imp], ip: [impAPIPort] },

    // the atc gateway on a cloud host → atc's daemon on the PC; last, so adding it
    // shifts no other grant
    { src: [tags.cloud], dst: ['home-pc'], ip: [`tcp:${homePC.daemonPort}`] },

    // the cluster's probe of imp's /health (#29) → imp's node, 443 only; last, so
    // adding it shifts no other grant
    { src: [tags.cloud], dst: [impHostname], ip: [`tcp:${impNode.httpsPort}`] },

    // imp's e2e nodes reach each other's API only, for the two-node moves suite; no
    // grant takes them to tag:imp. Last, so adding it shifts no other grant
    { src: [tags.impE2E], dst: [tags.impE2E], ip: [impAPIPort] },

    // members → nixie's web client and API on the host's 443. The first grant already covers it;
    // this one names the route, so it stays open if that grant narrows. Last, so adding it shifts
    // no other grant
    { src: ['autogroup:member'], dst: ['geoffcloud'], ip: [`tcp:${geoffcloudNode.httpsPort}`] },

    // nixie's route to impd: nixie's pod, as tag:cloud → imp's node, 443 only. It repeats the probe's
    // grant and gives nothing beyond it; grants union, so removing it breaks nixie once the probe's
    // grant no longer covers this route. Last, so adding it shifts no other grant
    { src: [tags.cloud], dst: [impHostname], ip: [`tcp:${impNode.httpsPort}`] },

    // the prod apply job → k3s's API on the host, and nothing else: Pulumi drives the cluster
    // through it, and every other provider the job uses is a public API. Last, so adding it shifts
    // no other grant
    { src: [tags.cloudDeploy], dst: ['geoffcloud'], ip: [`tcp:${k3sAPIPort}`] },

    // members keep k3s's API port on every device but the host, which is the only tag:cloud node,
    // so a k3s credential copied off the host works from no member device. Last, so adding it
    // shifts no other grant
    {
      src: ['autogroup:member'],
      dst: ['autogroup:member', tags.imp, tags.impE2E, tags.cloudDeploy],
      ip: [`tcp:${k3sAPIPort}`],
    },

    // the operator's Pulumi runs (preview, up, drift) on home-pc → k3s's API on the host. kubectl
    // by hand runs on the host over Tailscale SSH and needs no grant here. Last, so adding it
    // shifts no other grant
    { src: ['home-pc'], dst: ['geoffcloud'], ip: [`tcp:${k3sAPIPort}`] },
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
      dst: [tags.cloud],
      users: ['autogroup:nonroot', 'root'],
    },
  ],
};
