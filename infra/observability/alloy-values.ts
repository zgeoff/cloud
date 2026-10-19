import { alloyConfig } from './alloy-config.ts';
import { toHelmTplLiteral } from './to-helm-tpl-literal.ts';

// Alloy keeps its read positions here, on the node, so a restart resumes where it stopped. Without
// a position, Alloy reads a pod's log file from its end.
const storagePath = '/var/lib/alloy';

// Alloy as a DaemonSet with alloyConfig, which Prometheus scrapes through the chart's
// ServiceMonitor. The chart runs Helm's tpl over the config, so the config's own Go templates go
// in as literals.
export const alloyValues = {
  alloy: {
    storagePath,
    configMap: {
      content: toHelmTplLiteral(alloyConfig),
    },

    // /var/log from the host, read-only, for the journal and the pods' log files
    mounts: { varlog: true, extra: [{ name: 'storage', mountPath: storagePath }] },

    // the Go runtime collects garbage harder as the heap nears GOMEMLIMIT, below the limit
    extraEnv: [{ name: 'GOMEMLIMIT', value: '300MiB' }],
    resources: { requests: { cpu: '20m', memory: '128Mi' }, limits: { memory: '384Mi' } },
  },
  serviceMonitor: { enabled: true },
  controller: {
    volumes: {
      extra: [{ name: 'storage', hostPath: { path: storagePath, type: 'DirectoryOrCreate' } }],
    },
  },
};
