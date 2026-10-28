import { expect, test } from 'bun:test';
import { topology } from '@zgeoff/cloud-topology';
import { buildNixieImpConfig } from './build-nixie-imp-config.ts';

test('it builds the imp section that nixie ran with from packages/topology', () => {
  expect(buildNixieImpConfig(topology)).toStrictEqual({
    url: 'https://imps.geoff.cloud',
    host_addresses: [
      '104.250.100.18/24',
      '2401:a4a0:4:17f::1/64',
      '10.88.0.1/16',
      '100.69.47.33/32',
      'fd7a:115c:a1e0::ca36:2f22/128',
      '10.42.0.0/32',
      '10.42.0.1/24',
    ],
    egress_deny: ['10.42.0.0/16', '10.43.0.0/16'],
  });
});

test('it moves each address with the constant it comes from', () => {
  const moved = {
    ...topology,
    vm: {
      ...topology.vm,
      publicIPv4: '203.0.113.7',
      publicIPv4PrefixLength: 25,
      publicIPv6: '2001:db8::7',
      publicIPv6PrefixLength: 56,
    },
    tailnet: {
      ...topology.tailnet,
      nodes: {
        ...topology.tailnet.nodes,
        geoffcloud: { address: '100.100.1.2', addressIPv6: 'fd7a:115c:a1e0::1:2' },
      },
    },
    k3s: {
      ...topology.k3s,
      podCIDR: '10.52.0.0/16',
      serviceCIDR: '10.53.0.0/16',
      nodePodCIDR: '10.52.3.0/24',
    },
    podman: { bridge: 'podman1', bridgeAddress: '172.18.0.1', subnet: '172.18.0.0/16' },
    imp: { ...topology.imp, domain: 'imps.example.test' },
  };

  expect(buildNixieImpConfig(moved)).toStrictEqual({
    url: 'https://imps.example.test',
    host_addresses: [
      '203.0.113.7/25',
      '2001:db8::7/56',
      '172.18.0.1/16',
      '100.100.1.2/32',
      'fd7a:115c:a1e0::1:2/128',
      '10.52.3.0/32',
      '10.52.3.1/24',
    ],
    egress_deny: ['10.52.0.0/16', '10.53.0.0/16'],
  });
});

test('it carries the first pod address into the next octet at a byte boundary', () => {
  const config = buildNixieImpConfig({
    ...topology,
    k3s: { ...topology.k3s, nodePodCIDR: '10.42.255.255/32' },
  });

  expect(config.host_addresses.slice(-2)).toStrictEqual(['10.42.255.255/32', '10.43.0.0/32']);
});
