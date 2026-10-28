import { expect, test } from 'bun:test';
import { topologySchema } from './topology-schema.ts';

test('it accepts a complete topology as given', () => {
  const payload = {
    vm: {
      id: '0f289413-258f-4115-ac81-252000998fe0',
      publicIPv4: '104.250.100.18',
      publicIPv6: '2401:a4a0:4:17f::1',
      publicIPv4PrefixLength: 24,
      publicIPv6PrefixLength: 64,
    },
    tailnet: {
      cidr: '100.64.0.0/10',
      directPort: 41_641,
      tags: {
        cloud: 'tag:cloud',
        cloudDeploy: 'tag:cloud-deploy',
        imp: 'tag:imp',
        impE2E: 'tag:imp-e2e',
      },
      nodes: {
        geoffcloud: { address: '100.69.47.33', addressIPv6: 'fd7a:115c:a1e0::ca36:2f22' },
        homePC: { address: '100.67.122.120' },
        imp: { hostname: 'imp-geoffcloud', address: '100.75.9.119' },
      },
    },
    k3s: {
      podCIDR: '10.42.0.0/16',
      serviceCIDR: '10.43.0.0/16',
      nodePodCIDR: '10.42.0.0/24',
      apiPort: 6443,
      grafanaNodePort: 30_300,
    },
    podman: { bridge: 'podman0', bridgeAddress: '10.88.0.1', subnet: '10.88.0.0/16' },
    atc: { daemonPort: 8415, gatewayPort: 8414 },
    imp: { domain: 'imps.geoff.cloud', apiPort: 7070 },
    onePasswordConnect: { clusterIP: '10.43.82.198', port: 8000 },
    nodeExporter: { textfileDir: '/var/lib/node-exporter/textfile' },
  };

  expect(topologySchema.safeParse(payload).data).toStrictEqual(payload);
});

test('it rejects a key that the schema does not name', () => {
  const result = topologySchema.safeParse({
    vm: {
      id: '0f289413-258f-4115-ac81-252000998fe0',
      publicIPv4: '104.250.100.18',
      publicIPv6: '2401:a4a0:4:17f::1',
      publicIPv4PrefixLength: 24,
      publicIPv6PrefixLength: 64,
    },
    tailnet: {
      cidr: '100.64.0.0/10',
      directPort: 41_641,
      tags: {
        cloud: 'tag:cloud',
        cloudDeploy: 'tag:cloud-deploy',
        imp: 'tag:imp',
        impE2E: 'tag:imp-e2e',
      },
      nodes: {
        geoffcloud: { address: '100.69.47.33', addressIPv6: 'fd7a:115c:a1e0::ca36:2f22' },
        homePC: { address: '100.67.122.120' },
        imp: { hostname: 'imp-geoffcloud', address: '100.75.9.119' },
      },
    },
    k3s: {
      podCIDR: '10.42.0.0/16',
      serviceCIDR: '10.43.0.0/16',
      nodePodCIDR: '10.42.0.0/24',
      apiPort: 6443,
      grafanaNodePort: 30_300,
    },
    podman: { bridge: 'podman0', bridgeAddress: '10.88.0.1', subnet: '10.88.0.0/16' },
    atc: { daemonPort: 8415, gatewayPort: 8414, gatwayPort: 8414 },
    imp: { domain: 'imps.geoff.cloud', apiPort: 7070 },
    onePasswordConnect: { clusterIP: '10.43.82.198', port: 8000 },
    nodeExporter: { textfileDir: '/var/lib/node-exporter/textfile' },
  });

  expect(result.error?.issues).toPartiallyContain({ code: 'unrecognized_keys', path: ['atc'] });
});

test('it rejects a port outside 1 to 65535', () => {
  const result = topologySchema.safeParse({
    vm: {
      id: '0f289413-258f-4115-ac81-252000998fe0',
      publicIPv4: '104.250.100.18',
      publicIPv6: '2401:a4a0:4:17f::1',
      publicIPv4PrefixLength: 24,
      publicIPv6PrefixLength: 64,
    },
    tailnet: {
      cidr: '100.64.0.0/10',
      directPort: 41_641,
      tags: {
        cloud: 'tag:cloud',
        cloudDeploy: 'tag:cloud-deploy',
        imp: 'tag:imp',
        impE2E: 'tag:imp-e2e',
      },
      nodes: {
        geoffcloud: { address: '100.69.47.33', addressIPv6: 'fd7a:115c:a1e0::ca36:2f22' },
        homePC: { address: '100.67.122.120' },
        imp: { hostname: 'imp-geoffcloud', address: '100.75.9.119' },
      },
    },
    k3s: {
      podCIDR: '10.42.0.0/16',
      serviceCIDR: '10.43.0.0/16',
      nodePodCIDR: '10.42.0.0/24',
      apiPort: 6443,
      grafanaNodePort: 30_300,
    },
    podman: { bridge: 'podman0', bridgeAddress: '10.88.0.1', subnet: '10.88.0.0/16' },
    atc: { daemonPort: 8415, gatewayPort: 8414 },
    imp: { domain: 'imps.geoff.cloud', apiPort: 70_700 },
    onePasswordConnect: { clusterIP: '10.43.82.198', port: 8000 },
    nodeExporter: { textfileDir: '/var/lib/node-exporter/textfile' },
  });

  expect(result.error?.issues).toPartiallyContain({ path: ['imp', 'apiPort'] });
});

test('it rejects a tag without the tag: prefix', () => {
  const result = topologySchema.safeParse({
    vm: {
      id: '0f289413-258f-4115-ac81-252000998fe0',
      publicIPv4: '104.250.100.18',
      publicIPv6: '2401:a4a0:4:17f::1',
      publicIPv4PrefixLength: 24,
      publicIPv6PrefixLength: 64,
    },
    tailnet: {
      cidr: '100.64.0.0/10',
      directPort: 41_641,
      tags: {
        cloud: 'cloud',
        cloudDeploy: 'tag:cloud-deploy',
        imp: 'tag:imp',
        impE2E: 'tag:imp-e2e',
      },
      nodes: {
        geoffcloud: { address: '100.69.47.33', addressIPv6: 'fd7a:115c:a1e0::ca36:2f22' },
        homePC: { address: '100.67.122.120' },
        imp: { hostname: 'imp-geoffcloud', address: '100.75.9.119' },
      },
    },
    k3s: {
      podCIDR: '10.42.0.0/16',
      serviceCIDR: '10.43.0.0/16',
      nodePodCIDR: '10.42.0.0/24',
      apiPort: 6443,
      grafanaNodePort: 30_300,
    },
    podman: { bridge: 'podman0', bridgeAddress: '10.88.0.1', subnet: '10.88.0.0/16' },
    atc: { daemonPort: 8415, gatewayPort: 8414 },
    imp: { domain: 'imps.geoff.cloud', apiPort: 7070 },
    onePasswordConnect: { clusterIP: '10.43.82.198', port: 8000 },
    nodeExporter: { textfileDir: '/var/lib/node-exporter/textfile' },
  });

  expect(result.error?.issues).toPartiallyContain({ path: ['tailnet', 'tags', 'cloud'] });
});

test('it rejects a CIDR without its prefix length', () => {
  const result = topologySchema.safeParse({
    vm: {
      id: '0f289413-258f-4115-ac81-252000998fe0',
      publicIPv4: '104.250.100.18',
      publicIPv6: '2401:a4a0:4:17f::1',
      publicIPv4PrefixLength: 24,
      publicIPv6PrefixLength: 64,
    },
    tailnet: {
      cidr: '100.64.0.0/10',
      directPort: 41_641,
      tags: {
        cloud: 'tag:cloud',
        cloudDeploy: 'tag:cloud-deploy',
        imp: 'tag:imp',
        impE2E: 'tag:imp-e2e',
      },
      nodes: {
        geoffcloud: { address: '100.69.47.33', addressIPv6: 'fd7a:115c:a1e0::ca36:2f22' },
        homePC: { address: '100.67.122.120' },
        imp: { hostname: 'imp-geoffcloud', address: '100.75.9.119' },
      },
    },
    k3s: {
      podCIDR: '10.42.0.0',
      serviceCIDR: '10.43.0.0/16',
      nodePodCIDR: '10.42.0.0/24',
      apiPort: 6443,
      grafanaNodePort: 30_300,
    },
    podman: { bridge: 'podman0', bridgeAddress: '10.88.0.1', subnet: '10.88.0.0/16' },
    atc: { daemonPort: 8415, gatewayPort: 8414 },
    imp: { domain: 'imps.geoff.cloud', apiPort: 7070 },
    onePasswordConnect: { clusterIP: '10.43.82.198', port: 8000 },
    nodeExporter: { textfileDir: '/var/lib/node-exporter/textfile' },
  });

  expect(result.error?.issues).toPartiallyContain({ path: ['k3s', 'podCIDR'] });
});
