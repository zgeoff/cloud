// one probe target: its name, which the ServiceMonitor stamps on its series as the `target` label,
// what it probes, and the module it runs when not the default one
interface ProbeTarget<Module extends string> {
  readonly name: string;
  readonly url: string;
  readonly module?: Module;
}

interface ProbeValuesInputs<Modules extends Readonly<Record<string, unknown>>> {
  // the blackbox exporter's modules by name, and the one a target runs by default
  readonly modules: Modules;
  readonly module: keyof Modules & string;
  readonly targets: readonly ProbeTarget<keyof Modules & string>[];
}

// A blackbox exporter release's values: the chart's own image (its appVersion) and its
// securityContext (non-root, read-only root, no capabilities), and a ServiceMonitor that probes
// every target every 30s with the default module or the target's own
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
