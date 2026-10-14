import type { Output } from '@pulumi/pulumi';
import { exposure } from '@zgeoff/cloud-topology';

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

// The exposure registry's public host ports, in its order, each as its own edge rule. SSH, a
// tailnet port in the registry, stays public at the edge only until tailnet SSH works on the
// NixOS host (#6).
function buildRules(hostOnTailnet: boolean): readonly EdgeRule[] {
  const hostPorts = exposure.entries.filter((entry) => entry.kind === 'host-port');
  const ssh = hostPorts.find((entry) => entry.name === 'ssh');

  if (ssh?.port === undefined) {
    throw new Error('the exposure registry has no ssh entry with a port');
  }

  return [
    ...(hostOnTailnet
      ? []
      : [
          {
            name: 'ssh',
            protocol: ssh.protocol,
            port: String(ssh.port),
            description: 'SSH, until tailnet SSH (#6)',
          },
        ]),

    // the registry's schema gives every public host port its edge description
    ...hostPorts.flatMap((entry) =>
      entry.scope === 'public' && entry.edge !== undefined
        ? [
            {
              name: entry.name,
              protocol: entry.protocol,
              ...(entry.port === undefined ? {} : { port: String(entry.port) }),
              description: entry.edge,
            },
          ]
        : [],
    ),
  ];
}
