// one probe target: its name, which the ServiceMonitor stamps on its series as the `target` label,
// and what the module probes
interface ProbeTarget {
  readonly name: string;
  readonly url: string;
}

interface ProbeValuesInputs<Modules extends Readonly<Record<string, unknown>>> {
  // the blackbox exporter's modules by name, and the one each target runs
  readonly modules: Modules;
  readonly module: keyof Modules & string;
  readonly targets: readonly ProbeTarget[];
}

// A blackbox exporter release's values: the chart's own image (its appVersion) and its
// securityContext (non-root, read-only root, no capabilities), and a ServiceMonitor that probes
// every target every 30s with one module
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
