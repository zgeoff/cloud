import { expect, test } from 'bun:test';
import { alloyConfig } from './alloy-config.ts';
import { alloyValues } from './alloy-values.ts';
import { buildPodLogPositionsSeedScript } from './build-pod-log-positions-seed-script.ts';
import { toHelmTplLiteral } from './to-helm-tpl-literal.ts';

test("it runs Alloy's config from saved positions, seeded before each start, as a literal for the chart's tpl pass, and lets Prometheus scrape it", () => {
  expect(alloyValues).toStrictEqual({
    alloy: {
      storagePath: '/var/lib/alloy',
      configMap: { content: toHelmTplLiteral(alloyConfig) },
      mounts: { varlog: true, extra: [{ name: 'storage', mountPath: '/var/lib/alloy' }] },
      extraEnv: [{ name: 'GOMEMLIMIT', value: '300MiB' }],
      resources: { requests: { cpu: '20m', memory: '128Mi' }, limits: { memory: '384Mi' } },
    },
    serviceMonitor: { enabled: true },
    controller: {
      initContainers: [
        {
          name: 'seed-pod-log-positions',
          image: 'docker.io/grafana/alloy:v1.20.0',
          command: [
            'sh',
            '-c',
            buildPodLogPositionsSeedScript({
              podLogRoot: '/var/log/pods',
              seedFile: '/var/lib/alloy/pod-log-positions.yml',
            }),
          ],
          volumeMounts: [
            { name: 'varlog', mountPath: '/var/log', readOnly: true },
            { name: 'storage', mountPath: '/var/lib/alloy' },
          ],
        },
      ],
      volumes: {
        extra: [
          { name: 'storage', hostPath: { path: '/var/lib/alloy', type: 'DirectoryOrCreate' } },
        ],
      },
    },
  });
});

test('it keeps its read positions on a directory of the node, which outlives the container and the pod', () => {
  expect(alloyValues.alloy.mounts.extra).toStrictEqual([
    { name: 'storage', mountPath: alloyValues.alloy.storagePath },
  ]);

  expect(alloyValues.controller.volumes.extra).toStrictEqual([
    {
      name: 'storage',
      hostPath: { path: alloyValues.alloy.storagePath, type: 'DirectoryOrCreate' },
    },
  ]);
});
