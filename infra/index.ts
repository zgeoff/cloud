import { R2Bucket, getZoneOutput } from '@pulumi/cloudflare';
import { Acl } from '@pulumi/tailscale';
import { FirewallGroup, FirewallRule, Vm } from '@zgeoff/pulumi-onidel';
import { tailnetPolicy } from './tailnet-policy.ts';

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
