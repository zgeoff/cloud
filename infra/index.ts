import {
  DnsRecord,
  R2Bucket,
  ZeroTrustTunnelCloudflared,
  ZeroTrustTunnelCloudflaredConfig,
  getZeroTrustTunnelCloudflaredTokenOutput,
  getZoneOutput,
} from '@pulumi/cloudflare';
import { secret } from '@pulumi/pulumi';
import { Acl, TailnetKey } from '@pulumi/tailscale';
import { FirewallGroup, FirewallRule, Vm } from '@zgeoff/pulumi-onidel';
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

// The Onidel VM, made by hand on 2026-10-02 and adopted here (#4). Every input but
// the name replaces the VM, so protect and retainOnDelete keep a typo from
// destroying it. vdb (the 200 GB volume for imp's pool) has no API and is manual.
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
  },
  {
    import: '0f289413-258f-4115-ac81-252000998fe0',
    protect: true,
    retainOnDelete: true,
  },
);

export const geoffcloudIPv4 = geoffcloud.mainIpv4;

// Onidel's cloud firewall, outside the VM. Not attached yet: attaching it to the
// VM (firewallGroupId) closes every port it does not list.
const edge = new FirewallGroup('edge', { description: 'geoff.cloud edge' });

export const edgeFirewallID = edge.id;

interface EdgeRule {
  readonly name: string;
  readonly protocol: string;
  readonly port?: string;
  readonly description: string;
}

const edgeRules: readonly EdgeRule[] = [
  // SSH stays public until tailnet SSH works on the NixOS host (#6)
  { name: 'ssh', protocol: 'tcp', port: '22', description: 'SSH, until tailnet SSH (#6)' },
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

// mcp.geoff.cloud: atc's MCP on Geoff's PC, over the tailnet. `tailscale serve` on
// the PC terminates TLS with its *.ts.net certificate, hence originServerName. atc
// owns OAuth, so no Cloudflare Access on this hostname.
const tunnelConfig = new ZeroTrustTunnelCloudflaredConfig('edge', {
  accountId: accountID,
  tunnelId: tunnel.id,
  config: {
    ingresses: [
      {
        hostname: mcpHostname,
        service: `https://${homePC.dnsName}`,
        originRequest: {
          httpHostHeader: mcpHostname,
          originServerName: homePC.dnsName,
        },
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
