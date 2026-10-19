import { expect, test } from 'bun:test';
import { output } from '@pulumi/pulumi';
import { buildAlloyValues } from './alloy-values.ts';
import { buildPodLogPositionsSeedScript } from './build-pod-log-positions-seed-script.ts';

test("it runs Alloy's config from the ConfigMap it names, without the chart creating one, from saved positions seeded or repaired in the entry point before each start, and lets Prometheus scrape it", () => {
  const configMapName = output('alloy-config-1a2b3c4d');

  expect(buildAlloyValues(configMapName)).toStrictEqual({
    alloy: {
      storagePath: '/var/lib/alloy',
      configMap: { create: false, name: configMapName, key: 'config.alloy' },
      command: [
        'sh',
        '-c',
        `${buildPodLogPositionsSeedScript({
          podLogRoot: '/var/log/pods',
          seedFile: '/var/lib/alloy/pod-log-positions.yml',
          positionsFile: '/var/lib/alloy/loki.source.file.pods/positions.yml',
        })}exec /bin/alloy "$@"\n`,
        'alloy',
      ],
      mounts: { varlog: true, extra: [{ name: 'storage', mountPath: '/var/lib/alloy' }] },
      extraEnv: [{ name: 'GOMEMLIMIT', value: '300MiB' }],
      resources: { requests: { cpu: '20m', memory: '128Mi' }, limits: { memory: '384Mi' } },
    },
    serviceMonitor: { enabled: true },
    controller: {
      volumes: {
        extra: [
          { name: 'storage', hostPath: { path: '/var/lib/alloy', type: 'DirectoryOrCreate' } },
        ],
      },
    },
  });
});

test('it keeps its read positions on a directory of the node, which outlives the container and the pod', () => {
  const values = buildAlloyValues('alloy-config-1a2b3c4d');

  expect(values.alloy.mounts.extra).toStrictEqual([
    { name: 'storage', mountPath: values.alloy.storagePath },
  ]);

  expect(values.controller.volumes.extra).toStrictEqual([
    {
      name: 'storage',
      hostPath: { path: values.alloy.storagePath, type: 'DirectoryOrCreate' },
    },
  ]);
});
