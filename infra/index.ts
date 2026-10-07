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
import { FirewallGroup, FirewallRule, Vm } from '@zgeoff/pulumi-onidel';
import { buildEdgeRules } from './build-edge-rules.ts';
import { createClusterWorkloads } from './cluster-workloads.ts';
import { createTunnelRoutes } from './create-tunnel-routes.ts';
import { createHealthCheck } from './health-check.ts';
import { loadClusterInputs } from './load-cluster-inputs.ts';
import { requireCloudflareAccountID } from './require-cloudflare-account-id.ts';
import { tailnetPolicy } from './tailnet-policy.ts';

// K3S_KUBECONFIG comes from op://cloud/k3s-kubeconfig, and ONEPASSWORD_CONNECT_CREDENTIALS
// from op://cloud/onepassword-connect-credentials. The stack's "cluster" config says
// whether the cluster is managed, so a missing value fails the run before any resource
// registers, instead of planning to delete the cluster's resources.
const clusterInputs = loadClusterInputs(new Config(), process.env);
const accountID = requireCloudflareAccountID(process.env['CLOUDFLARE_ACCOUNT_ID']);

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
    tags: ['tag:cloud'],
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

// imp's key (tag:imp) for impd nodes: dev, e2e and hosts. imp's scripts read it from
// op://cloud/imp-tailscale-authkey, so Pulumi writes each new key into that item.
// Expiry is Tailscale's 90-day maximum; an apply after expiry mints a fresh one.
const impKey = new TailnetKey(
  'imp',
  {
    description: 'impd nodes',
    tags: ['tag:imp'],
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
  'imp-geoffcloud',
  {
    description: 'imp node on geoffcloud',
    tags: ['tag:imp'],
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

// The Onidel VM, made by hand on 2026-10-02 and adopted here (#4). Every input but
// the name replaces the VM, so protect and retainOnDelete keep a typo from
// destroying it. vdb (the 200 GB volume for imp's pool) has no API and is manual.
// Set once the NixOS host answers tailnet SSH (`pulumi config set hostOnTailnet true`):
// the edge firewall attaches to the VM and public SSH leaves it.
const hostOnTailnet = new Config().getBoolean('hostOnTailnet') ?? false;

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
    import: '0f289413-258f-4115-ac81-252000998fe0',
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
const workloads =
  clusterInputs === undefined
    ? undefined
    : createClusterWorkloads({
        kubeconfig: clusterInputs.kubeconfig,
        tunnelToken,
        ...(clusterInputs.atcGateway === undefined ? {} : { atcGateway: clusterInputs.atcGateway }),
        onePasswordConnect: {
          credentials: clusterInputs.onePasswordConnectCredentials,
        },
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

// External health check (#8). ALERT_WEBHOOK_URL is optional; without it, state
// changes show only in the Worker's logs.
const healthCheck = await createHealthCheck({
  accountID,
  targets:
    workloads?.atcGatewayRoute === undefined
      ? []
      : [{ name: 'atc', url: workloads.atcGatewayRoute.healthURL }],
  alertURL: process.env['ALERT_WEBHOOK_URL'],
});

export const healthCheckCron = healthCheck.schedules;
