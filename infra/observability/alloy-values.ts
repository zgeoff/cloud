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

    // /var/log from the host, read-only, for the journal and the pods' log files
    mounts: { varlog: true, extra: [{ name: 'storage', mountPath: alloyPaths.storage }] },

    // the Go runtime collects garbage harder as the heap nears GOMEMLIMIT, below the limit
    extraEnv: [{ name: 'GOMEMLIMIT', value: '300MiB' }],
    resources: { requests: { cpu: '20m', memory: '128Mi' }, limits: { memory: '384Mi' } },
  },
  serviceMonitor: { enabled: true },
  controller: {
    // before each start, the seed of read positions that Alloy's pod-log source imports when it has
    // none of its own; the image is the chart's appVersion, which the Alloy container runs
    initContainers: [
      {
        name: 'seed-pod-log-positions',
        image: 'docker.io/grafana/alloy:v1.20.0',
        command: [
          'sh',
          '-c',
          buildPodLogPositionsSeedScript({
            podLogRoot: alloyPaths.podLogs,
            seedFile: alloyPaths.podLogPositionsSeed,
            positionsFile: alloyPaths.podLogPositions,
          }),
        ],
        volumeMounts: [
          { name: 'varlog', mountPath: '/var/log', readOnly: true },
          { name: 'storage', mountPath: alloyPaths.storage },
        ],
      },
    ],
    volumes: {
      extra: [
        { name: 'storage', hostPath: { path: alloyPaths.storage, type: 'DirectoryOrCreate' } },
      ],
    },
  },
};
