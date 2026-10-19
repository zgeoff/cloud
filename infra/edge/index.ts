import { R2Bucket, ZoneSetting, getZoneOutput } from '@pulumi/cloudflare';
import type { Output } from '@pulumi/pulumi';
import { topology } from '@zgeoff/cloud-topology';
import { FirewallGroup, FirewallRule, Vm } from '@zgeoff/pulumi-onidel';
import { buildEdgeRules } from './build-edge-rules.ts';

interface EdgeInputs {
  readonly accountID: string;

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

export function createEdge(inputs: EdgeInputs): EdgeOutputs {
  const zone = getZoneOutput({ filter: { name: domain } });

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

function createHost(hostOnTailnet: boolean): { readonly firewall: FirewallGroup; readonly vm: Vm } {
  // Attaching Onidel's cloud firewall to the VM closes every port it does not list.
  const edge = new FirewallGroup('edge', { description: 'geoff.cloud edge' });

  // Every input but name replaces the VM, so protect/retainOnDelete guard typos. vdb (200 GB,
  // imp's pool) has no API and is manual.
  const geoffcloud = new Vm(
    'geoffcloud',
    {
      name: 'geoffcloud',
      location: 'Melbourne',
      cpu: 8,
      ram: 32_768,
      disk: 240,

      // Ubuntu 26.04 LTS x64; the NixOS reinstall does not go through this field
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
