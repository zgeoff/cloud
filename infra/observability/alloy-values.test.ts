import { expect, test } from 'bun:test';
import { alloyConfig } from './alloy-config.ts';
import { alloyValues } from './alloy-values.ts';
import { toHelmTplLiteral } from './to-helm-tpl-literal.ts';

test("it runs Alloy's config from saved positions, as a literal for the chart's tpl pass, and lets Prometheus scrape it", () => {
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
