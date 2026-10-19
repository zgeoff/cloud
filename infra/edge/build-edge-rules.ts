import type { Output } from '@pulumi/pulumi';
import { exposure } from '@zgeoff/cloud-topology';

interface EdgeRulesInputs {
  readonly hostOnTailnet: boolean;
  readonly firewallID: Output<string>;
}

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

const anywhere = [
  { family: 'v4', subnet: '0.0.0.0' },
  { family: 'v6', subnet: '::' },
] as const;

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
