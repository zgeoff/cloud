// the ServiceMonitor stamps a target's name on its series as the `target` label
interface ProbeTarget<Module extends string> {
  readonly name: string;
  readonly url: string;
  readonly module?: Module;
}

interface ProbeValuesInputs<Modules extends Readonly<Record<string, unknown>>> {
  readonly modules: Modules;
  readonly module: keyof Modules & string;
  readonly targets: readonly ProbeTarget<keyof Modules & string>[];
}

export function buildProbeValues<Modules extends Readonly<Record<string, unknown>>>(
  inputs: ProbeValuesInputs<Modules>,
) {
  return {
    podSecurityContext: { seccompProfile: { type: 'RuntimeDefault' } },
    resources: { requests: { cpu: '10m', memory: '16Mi' }, limits: { memory: '64Mi' } },
    config: { modules: inputs.modules },
    serviceMonitor: {
      enabled: true,
      defaults: { module: inputs.module, interval: '30s', scrapeTimeout: '10s' },
      targets: inputs.targets,
    },
  };
}
