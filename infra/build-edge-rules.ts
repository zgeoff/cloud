import type { Output } from '@pulumi/pulumi';

interface EdgeRulesInputs {
  // set once the NixOS host answers tailnet SSH: public SSH leaves the edge then
  readonly hostOnTailnet: boolean;
  readonly firewallID: Output<string>;
}

// one FirewallRule: its resource name and its arguments
interface EdgeRuleResource {
  readonly name: string;
  readonly args: {
    readonly firewallId: Output<string>;
    readonly protocol: string;
    readonly port?: string;
    readonly subnet: string;
    readonly subnetSize: number;
    readonly description: string;
  };
}

// every rule opens to the whole of each address family
const anywhere = [
  { family: 'v4', subnet: '0.0.0.0' },
  { family: 'v6', subnet: '::' },
] as const;

// Onidel's edge firewall rules, one per rule and address family, in that order: what the
// edge lets in once the firewall attaches to the VM, which closes every port it does not
// list.
export function buildEdgeRules(inputs: EdgeRulesInputs): readonly EdgeRuleResource[] {
  return buildRules(inputs.hostOnTailnet).flatMap((rule) =>
    anywhere.map((target) => ({
      name: `edge-${rule.name}-${target.family}`,
      args: {
        firewallId: inputs.firewallID,
        protocol: rule.protocol,
        ...(rule.port === undefined ? {} : { port: rule.port }),
        subnet: target.subnet,
        subnetSize: 0,
        description: rule.description,
      },
    })),
  );
}

interface EdgeRule {
  readonly name: string;
  readonly protocol: string;
  readonly port?: string;
  readonly description: string;
}

function buildRules(hostOnTailnet: boolean): readonly EdgeRule[] {
  return [
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
}
