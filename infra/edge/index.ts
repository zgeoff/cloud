import { R2Bucket, ZoneSetting, getZoneOutput } from '@pulumi/cloudflare';
import type { Output } from '@pulumi/pulumi';
import { topology } from '@zgeoff/cloud-topology';
import { FirewallGroup, FirewallRule, Vm } from '@zgeoff/pulumi-onidel';
import { buildEdgeRules } from './build-edge-rules.ts';

interface EdgeInputs {
  // the Cloudflare account every Cloudflare resource belongs to
  readonly accountID: string;

  // set once NixOS answers tailnet SSH: attaches the edge firewall and drops public SSH
  readonly hostOnTailnet: boolean;
}

interface EdgeOutputs {
  readonly domain: string;
  readonly zoneID: Output<string>;
  readonly backupsBucket: Output<string>;
  readonly edgeFirewallID: Output<string>;
  readonly geoffcloudIPv4: Output<string>;
  readonly alwaysHTTPSValue: ZoneSetting['value'];
}

const domain = 'geoff.cloud';

// The edge: geoff.cloud's zone and its settings, the backups bucket, and the Onidel VM behind its
// cloud firewall
export function createEdge(inputs: EdgeInputs): EdgeOutputs {
  const zone = getZoneOutput({ filter: { name: domain } });

  // restic repositories for imp and the k3s datastore snapshots (#9)
  const backups = new R2Bucket('backups', {
    accountId: inputs.accountID,
    name: 'geoff-cloud-backups',
    location: 'oc',
  });

  const host = createHost(inputs.hostOnTailnet);

  // Redirect plain http to https on every hostname: a misconfigured client must not send
  // a bearer token or an authorization code over http, even only as far as the edge.
  const alwaysHTTPS = new ZoneSetting('always-use-https', {
    zoneId: zone.zoneId,
    settingId: 'always_use_https',
    value: 'on',
  });

  return {
    domain,
    zoneID: zone.zoneId,
    backupsBucket: backups.name,
    edgeFirewallID: host.firewall.id,
    geoffcloudIPv4: host.vm.mainIpv4,
    alwaysHTTPSValue: alwaysHTTPS.value,
  };
}

// the VM behind its cloud firewall, and the firewall's rules
function createHost(hostOnTailnet: boolean): { readonly firewall: FirewallGroup; readonly vm: Vm } {
  // Onidel's cloud firewall, outside the VM. Attaching it closes every port it does
  // not list.
  const edge = new FirewallGroup('edge', { description: 'geoff.cloud edge' });

  // The Onidel VM, hand-made on 2026-10-02 and adopted here (#4): every input but name replaces
  // it, so protect/retainOnDelete guard typos, and vdb (200 GB, imp's pool, no API) is manual.
  // Once NixOS answers tailnet SSH, `pulumi config set hostOnTailnet true` attaches edge, drops public SSH.
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

  const edgeRuleResources: FirewallRule[] = [];

  for (const rule of buildEdgeRules({ hostOnTailnet, firewallID: edge.id })) {
    edgeRuleResources.push(new FirewallRule(rule.name, rule.args));
  }

  return { firewall: edge, vm: geoffcloud };
}
