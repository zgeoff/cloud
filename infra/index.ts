import {
  DnsRecord,
  R2Bucket,
  ZeroTrustTunnelCloudflared,
  ZeroTrustTunnelCloudflaredConfig,
  getZeroTrustTunnelCloudflaredTokenOutput,
  getZoneOutput,
} from '@pulumi/cloudflare';
import { Command } from '@pulumi/command/local';
import { Config, secret } from '@pulumi/pulumi';
import { Acl, TailnetKey } from '@pulumi/tailscale';
import { FirewallGroup, FirewallRule, Vm } from '@zgeoff/pulumi-onidel';
import { createClusterWorkloads } from './cluster-workloads.ts';
import { createHealthCheck } from './health-check.ts';
import { homePC, tailnetPolicy } from './tailnet-policy.ts';

const accountID = process.env['CLOUDFLARE_ACCOUNT_ID'];

if (accountID === undefined) {
  throw new Error('CLOUDFLARE_ACCOUNT_ID is unset; run through `op run --env-file=../.env`');
}

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
    recreateIfInvalid: 'always',
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
    recreateIfInvalid: 'always',
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

interface EdgeRule {
  readonly name: string;
  readonly protocol: string;
  readonly port?: string;
  readonly description: string;
}

const edgeRules: readonly EdgeRule[] = [
  // SSH stays public until tailnet SSH works on the NixOS host (#6)
  ...(hostOnTailnet
    ? []
    : [{ name: 'ssh', protocol: 'tcp', port: '22', description: 'SSH, until tailnet SSH (#6)' }]),
  {
    name: 'tailscale',
    protocol: 'udp',
    port: '41641',
    description: 'Tailscale direct connections',
  },
  { name: 'icmp', protocol: 'icmp', description: 'ICMP' },
];

const edgeRuleResources: FirewallRule[] = [];

const anywhere = [
  { family: 'v4', subnet: '0.0.0.0' },
  { family: 'v6', subnet: '::' },
] as const;

for (const rule of edgeRules) {
  for (const target of anywhere) {
    edgeRuleResources.push(
      new FirewallRule(`edge-${rule.name}-${target.family}`, {
        firewallId: edge.id,
        protocol: rule.protocol,
        ...(rule.port === undefined ? {} : { port: rule.port }),
        subnet: target.subnet,
        subnetSize: 0,
        description: rule.description,
      }),
    );
  }
}

// Public ingress (#7). One tunnel for every public hostname under geoff.cloud;
// cloudflared runs in k3s with the token below. Each workload brings its own auth.
const tunnel = new ZeroTrustTunnelCloudflared('edge', {
  accountId: accountID,
  name: 'geoff-cloud',
  configSrc: 'cloudflare',
});

const mcpHostname = `mcp.${domain}`;

// mcp.geoff.cloud: atc's MCP on Geoff's PC, bound to the PC's tailnet address. The
// hop is plain HTTP inside WireGuard, and the tailnet policy lets only tag:cloud
// reach the port. atc owns OAuth, so no Cloudflare Access on this hostname.
const tunnelConfig = new ZeroTrustTunnelCloudflaredConfig('edge', {
  accountId: accountID,
  tunnelId: tunnel.id,
  config: {
    ingresses: [
      {
        hostname: mcpHostname,

        // the IP, not the MagicDNS name: CoreDNS in k3s does not forward to 100.100.100.100
        service: `http://${homePC.ip}:${homePC.mcpPort}`,
        originRequest: { httpHostHeader: mcpHostname },
      },
      { service: 'http_status:404' },
    ],
  },
});

export const tunnelConfigVersion = tunnelConfig.version;

const mcpRecord = new DnsRecord('mcp', {
  zoneId: zone.zoneId,
  name: mcpHostname,
  type: 'CNAME',
  content: tunnel.id.apply((id) => `${id}.cfargotunnel.com`),
  proxied: true,
  ttl: 1,
});

export const mcpURL = mcpRecord.name.apply((name) => `https://${name}`);

// cloudflared's credential; it becomes a k3s Secret once the cluster exists (#6)
export const tunnelToken = secret(
  getZeroTrustTunnelCloudflaredTokenOutput({ accountId: accountID, tunnelId: tunnel.id }).token,
);

// k3s workloads, once the cluster exists (#6). K3S_KUBECONFIG comes from
// op://cloud/k3s-kubeconfig; without it the program skips the cluster.
const kubeconfig = process.env['K3S_KUBECONFIG'];

const workloads =
  kubeconfig === undefined || kubeconfig === ''
    ? undefined
    : createClusterWorkloads({ kubeconfig, tunnelToken });

export const grafanaURL = workloads?.grafanaURL;
export const grafanaAdminPassword = workloads?.grafanaAdminPassword;

// External health check (#8). ALERT_WEBHOOK_URL is optional; without it, state
// changes show only in the Worker's logs.
const healthCheck = await createHealthCheck({
  accountID,
  targets: [{ name: 'mcp', url: `https://${mcpHostname}/.well-known/oauth-protected-resource` }],
  alertURL: process.env['ALERT_WEBHOOK_URL'],
});

export const healthCheckCron = healthCheck.schedules;
