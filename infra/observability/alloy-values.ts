import type { Input } from '@pulumi/pulumi';
import { alloyConfigKey } from './alloy-config-key.ts';
import { alloyPaths } from './alloy-paths.ts';
import { buildPodLogPositionsSeedScript } from './build-pod-log-positions-seed-script.ts';

// Alloy as a DaemonSet that reads its config from the ConfigMap configMapName, which the chart
// mounts without creating one, and that Prometheus scrapes through the chart's ServiceMonitor.
export function buildAlloyValues(configMapName: Input<string>) {
  return {
    alloy: {
      storagePath: alloyPaths.storage,
      configMap: { create: false, name: configMapName, key: alloyConfigKey },

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
}
