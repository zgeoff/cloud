// the program's entry point: it wires every top-level module, one import each
/* oxlint-disable import/max-dependencies */
import {
  R2Bucket,
  ZeroTrustTunnelCloudflared,
  ZoneSetting,
  getZeroTrustTunnelCloudflaredTokenOutput,
  getZoneOutput,
} from '@pulumi/cloudflare';
import { Command } from '@pulumi/command/local';
import { Config, secret } from '@pulumi/pulumi';
import { Acl, TailnetKey } from '@pulumi/tailscale';
import { topology } from '@zgeoff/cloud-topology';
import { FirewallGroup, FirewallRule, Vm } from '@zgeoff/pulumi-onidel';
import { buildEdgeRules } from './build-edge-rules.ts';
import { createClusterWorkloads } from './cluster-workloads.ts';
import { createTunnelRoutes } from './create-tunnel-routes.ts';
import { createHealthCheck } from './health-check.ts';
import { loadInputs } from './inputs/load-inputs.ts';
import { tailnetPolicy } from './tailnet-policy.ts';

// The one place the program reads its stack config and env (.env's op:// refs, through `op
// run`); every value is checked before any resource registers.
const inputs = loadInputs(new Config(), process.env);
const accountID = inputs.accountID;

export const domain = 'geoff.cloud';
const zone = getZoneOutput({ filter: { name: domain } });

export const zoneID = zone.zoneId;

// restic repositories for imp and the k3s datastore snapshots (#9)
const backups = new R2Bucket('backups', {
  accountId: accountID,
  name: 'geoff-cloud-backups',
  location: 'oc',
});

export const backupsBucket = backups.name;

// CAUTION: this resource owns the whole tailnet policy file (#5)
const policy = new Acl('tailnet-policy', {
  acl: JSON.stringify(tailnetPolicy, null, 2),
  overwriteExistingContent: true,
});

export const tailnetPolicyID = policy.id;

// The host's own tailnet node (tag:cloud), joined once by the NixOS install (#6).
// Single-use and preauthorized; the node keeps its identity in /var/lib/tailscale.
const hostKey = new TailnetKey(
  'geoffcloud-host',
  {
    description: 'geoffcloud host join',
    tags: [topology.tailnet.tags.cloud],
    reusable: false,
    ephemeral: false,
    preauthorized: true,
    expiry: 7 * 24 * 60 * 60,

    // single use: the host joined once, so the key reads as used. 'always' would mint a
    // fresh key on every apply and show as drift on every preview. A reinstall that needs
    // a new key replaces this resource on purpose (`pulumi up --replace`).
    recreateIfInvalid: 'never',
  },
  { dependsOn: [policy] },
);

export const hostAuthKey = hostKey.key;

// imp's key (tag:imp) for impd nodes, at Tailscale's 90-day maximum expiry (an apply after expiry
// mints a fresh one); imp's dev.sh reads it from op://cloud/imp-tailscale-authkey, so Pulumi writes
// each new key into that item. E2e suites use tag:imp-e2e with their own OAuth client (docs/runbooks/imp-e2e-tailnet.md).
const impKey = new TailnetKey(
  'imp',
  {
    description: 'impd nodes',
    tags: [topology.tailnet.tags.imp],
    reusable: true,
    ephemeral: true,
    preauthorized: true,
    expiry: 90 * 24 * 60 * 60,
    recreateIfInvalid: 'always',
  },
  { dependsOn: [policy] },
);

const impKeySync = new Command('imp-key-to-1password', {
  // op treats a piped stdin as a JSON template, so read the key first
  create:
    'key=$(cat) && op item edit imp-tailscale-authkey --vault cloud "credential=$key" < /dev/null > /dev/null',
  stdin: impKey.key,
  triggers: [impKey.id],
  logging: 'none',
});

export const impKeySyncID = impKeySync.id;

// imp's node on geoffcloud is long-lived, so it must not be ephemeral: Tailscale
// removes an offline ephemeral node, and a long reboot would lose imp-geoffcloud.
// Single-use, for the reinstall only; tank/imp keeps the node state after that.
const impHostKey = new TailnetKey(
  topology.tailnet.nodes.imp.hostname,
  {
    description: 'imp node on geoffcloud',
    tags: [topology.tailnet.tags.imp],
    reusable: false,
    ephemeral: false,
    preauthorized: true,
    expiry: 7 * 24 * 60 * 60,

    // as for the host's key: a reinstall replaces it on purpose (runbook step 3)
    recreateIfInvalid: 'never',
  },
  { dependsOn: [policy] },
);

export const impHostAuthKey = impHostKey.key;

// The Onidel VM, hand-made on 2026-10-02 and adopted here (#4): every input but name replaces
// it, so protect/retainOnDelete guard typos, and vdb (200 GB, imp's pool, no API) is manual.
// Once NixOS answers tailnet SSH, `pulumi config set hostOnTailnet true` attaches edge, drops public SSH.
const hostOnTailnet = inputs.hostOnTailnet;

// Onidel's cloud firewall, outside the VM. Attaching it closes every port it does
// not list.
const edge = new FirewallGroup('edge', { description: 'geoff.cloud edge' });

export const edgeFirewallID = edge.id;

const geoffcloud = new Vm(
  'geoffcloud',
  {
    name: 'geoffcloud',
    location: 'Melbourne',
    cpu: 8,
    ram: 32_768,
    disk: 240,

    // Ubuntu 26.04 LTS x64; the NixOS reinstall (#6) does not go through this field
    os: 24,
    ...(hostOnTailnet ? { firewallGroupId: edge.id } : {}),
  },
  {
    import: topology.vm.id,
    protect: true,
    retainOnDelete: true,
  },
);

export const geoffcloudIPv4 = geoffcloud.mainIpv4;
const edgeRuleResources: FirewallRule[] = [];

for (const rule of buildEdgeRules({ hostOnTailnet, firewallID: edge.id })) {
  edgeRuleResources.push(new FirewallRule(rule.name, rule.args));
}

// Public ingress (#7). One tunnel for every public hostname under geoff.cloud;
// cloudflared runs in k3s with the token below. Each workload brings its own auth.
const tunnel = new ZeroTrustTunnelCloudflared('edge', {
  accountId: accountID,
  name: 'geoff-cloud',
  configSrc: 'cloudflare',
});

// Redirect plain http to https on every hostname: a misconfigured client must not send
// a bearer token or an authorization code over http, even only as far as the edge.
const alwaysHTTPS = new ZoneSetting('always-use-https', {
  zoneId: zone.zoneId,
  settingId: 'always_use_https',
  value: 'on',
});

export const alwaysHTTPSValue = alwaysHTTPS.value;

// cloudflared's credential; it becomes a k3s Secret once the cluster exists (#6)
export const tunnelToken = secret(
  getZeroTrustTunnelCloudflaredTokenOutput({ accountId: accountID, tunnelId: tunnel.id }).token,
);

// k3s workloads (#6), with their inputs checked at the top of the program
const clusterInputs = inputs.cluster;

const workloads =
  clusterInputs === undefined
    ? undefined
    : createClusterWorkloads({
        kubeconfig: clusterInputs.kubeconfig,
        tunnelToken,
        alertWebhookURL: clusterInputs.alertWebhookURL,
        ...(clusterInputs.atcGateway === undefined ? {} : { atcGateway: clusterInputs.atcGateway }),
        onePasswordConnect: {
          credentials: clusterInputs.onePasswordConnectCredentials,
        },
        ...(clusterInputs.nixie === undefined ? {} : { nixie: clusterInputs.nixie }),
        zoneID: zone.zoneId,
      });

// the tunnel's one route: atc.geoff.cloud, a workload in k3s
const routes = createTunnelRoutes({
  accountID,
  zoneID: zone.zoneId,
  tunnelID: tunnel.id,
  atcRoute: workloads?.atcGatewayRoute,
});

export const tunnelConfigVersion = routes.configVersion;
export const atcURL = routes.atcURL;
export const onePasswordConnectServiceURL = workloads?.onePasswordConnectServiceURL;
export const grafanaURL = workloads?.grafanaURL;
export const grafanaAdminPassword = workloads?.grafanaAdminPassword;
export const atcGatewayServiceURL = workloads?.atcGatewayServiceURL;
export const nixieURL = workloads?.nixieURL;

// External health check (#8). ALERT_WEBHOOK_URL is optional; without it, state
// changes show only in the Worker's logs.
const healthCheck = await createHealthCheck({
  accountID,
  targets:
    workloads?.atcGatewayRoute === undefined
      ? []
      : [{ name: 'atc', url: workloads.atcGatewayRoute.healthURL }],
  alertURL: inputs.alertURL,
});

export const healthCheckCron = healthCheck.schedules;
