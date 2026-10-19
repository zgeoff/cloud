import { alloyConfig } from './alloy-config.ts';
import { alloyPaths } from './alloy-paths.ts';
import { buildPodLogPositionsSeedScript } from './build-pod-log-positions-seed-script.ts';
import { toHelmTplLiteral } from './to-helm-tpl-literal.ts';

// Alloy as a DaemonSet with alloyConfig, which Prometheus scrapes through the chart's
// ServiceMonitor. The chart runs Helm's tpl over the config, so the config's own Go templates go
// in as literals.
export const alloyValues = {
  alloy: {
    storagePath: alloyPaths.storage,
    configMap: {
      content: toHelmTplLiteral(alloyConfig),
    },

    // the seed script before each Alloy start, a restart of the container included, then the
    // image's Alloy with the chart's arguments
    command: [
      'sh',
      '-c',
      `${buildPodLogPositionsSeedScript({
        podLogRoot: alloyPaths.podLogs,
        seedFile: alloyPaths.podLogPositionsSeed,
        positionsFile: alloyPaths.podLogPositions,
      })}exec /bin/alloy "$@"\n`,
      'alloy',
    ],

    // /var/log from the host, read-only, for the journal and the pods' log files
    mounts: { varlog: true, extra: [{ name: 'storage', mountPath: alloyPaths.storage }] },

    // the Go runtime collects garbage harder as the heap nears GOMEMLIMIT, below the limit
    extraEnv: [{ name: 'GOMEMLIMIT', value: '300MiB' }],
    resources: { requests: { cpu: '20m', memory: '128Mi' }, limits: { memory: '384Mi' } },
  },
  serviceMonitor: { enabled: true },
  controller: {
    volumes: {
      extra: [
        { name: 'storage', hostPath: { path: alloyPaths.storage, type: 'DirectoryOrCreate' } },
      ],
    },
  },
};
