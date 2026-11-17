import { expect, test } from 'bun:test';
import { exposure, topology } from '@zgeoff/cloud-topology';
import { buildNixieSpendStopConfig } from './build-nixie-spend-stop-config.ts';

test('it points nixie at the control relay and the model listener from packages/topology', () => {
  expect(buildNixieSpendStopConfig(topology, exposure)).toStrictEqual({
    control: 'http://100.69.47.33:8791',
    token: 'deployment:gateway-control',
    modelURL: 'http://10.88.0.1:8789',
  });
});

test('it moves each URL with the constant and the registry entry it comes from', () => {
  const moved = {
    ...topology,
    tailnet: {
      ...topology.tailnet,
      nodes: { ...topology.tailnet.nodes, geoffcloud: { address: '100.64.0.9' } },
    },
    podman: { ...topology.podman, bridgeAddress: '10.89.0.1' },
  };

  const entries = exposure.entries.map((entry) =>
    entry.name === 'model-gateway-model' ? { ...entry, port: 9789 } : entry,
  );

  expect(buildNixieSpendStopConfig(moved, { ...exposure, entries })).toStrictEqual({
    control: 'http://100.64.0.9:8791',
    token: 'deployment:gateway-control',
    modelURL: 'http://10.89.0.1:9789',
  });
});
