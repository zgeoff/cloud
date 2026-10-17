import { expect, test } from 'bun:test';
import { requireExposureMatchesTopology } from './require-exposure-matches-topology.ts';

test('it accepts registry ports that equal their constants', () => {
  expect(() => {
    requireExposureMatchesTopology(
      {
        entries: [
          {
            name: 'tailscale',
            kind: 'host-port',
            protocol: 'udp',
            port: 41_641,
            scope: 'public',
            edge: 'Tailscale direct connections',
            reason: 'direct connections',
          },
          {
            name: 'atc-daemon',
            kind: 'host-port',
            protocol: 'tcp',
            port: 8415,
            scope: 'host',
            interface: 'cni0',
            admission: true,
            reason: 'the gateway',
          },
          {
            name: 'k3s-api',
            kind: 'host-port',
            protocol: 'tcp',
            port: 6443,
            scope: 'tailnet',
            reason: 'the cluster API',
          },
          {
            name: 'grafana',
            kind: 'host-port',
            protocol: 'tcp',
            port: 30_300,
            scope: 'tailnet',
            reason: 'grafana',
          },
        ],
      },
      {
        vm: {
          id: '0f289413-258f-4115-ac81-252000998fe0',
          publicIPv4: '104.250.100.18',
          publicIPv6: '2401:a4a0:4:17f::1',
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
            geoffcloud: { address: '100.69.47.33' },
            homePC: { address: '100.67.122.120' },
            imp: { hostname: 'imp-geoffcloud', address: '100.75.9.119' },
          },
        },
        k3s: {
          podCIDR: '10.42.0.0/16',
          serviceCIDR: '10.43.0.0/16',
          apiPort: 6443,
          grafanaNodePort: 30_300,
        },
        docker: { bridgeAddress: '172.17.0.1', subnet: '172.17.0.0/16' },
        atc: { daemonPort: 8415, gatewayPort: 8414 },
        imp: { domain: 'imps.geoff.cloud', apiPort: 7070 },
        onePasswordConnect: { clusterIP: '10.43.82.198', port: 8000 },
        nodeExporter: { textfileDir: '/var/lib/node-exporter/textfile' },
      },
    );
  }).not.toThrow();
});

test('it names every registry port that differs from its constant, and a missing entry', () => {
  expect(() => {
    requireExposureMatchesTopology(
      {
        entries: [
          {
            name: 'tailscale',
            kind: 'host-port',
            protocol: 'udp',
            port: 41_642,
            scope: 'public',
            edge: 'Tailscale direct connections',
            reason: 'direct connections',
          },
          {
            name: 'atc-daemon',
            kind: 'host-port',
            protocol: 'tcp',
            port: 8415,
            scope: 'host',
            interface: 'cni0',
            admission: true,
            reason: 'the gateway',
          },
          {
            name: 'k3s-api',
            kind: 'host-port',
            protocol: 'tcp',
            port: 6444,
            scope: 'tailnet',
            reason: 'the cluster API',
          },
        ],
      },
      {
        vm: {
          id: '0f289413-258f-4115-ac81-252000998fe0',
          publicIPv4: '104.250.100.18',
          publicIPv6: '2401:a4a0:4:17f::1',
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
            geoffcloud: { address: '100.69.47.33' },
            homePC: { address: '100.67.122.120' },
            imp: { hostname: 'imp-geoffcloud', address: '100.75.9.119' },
          },
        },
        k3s: {
          podCIDR: '10.42.0.0/16',
          serviceCIDR: '10.43.0.0/16',
          apiPort: 6443,
          grafanaNodePort: 30_300,
        },
        docker: { bridgeAddress: '172.17.0.1', subnet: '172.17.0.0/16' },
        atc: { daemonPort: 8415, gatewayPort: 8414 },
        imp: { domain: 'imps.geoff.cloud', apiPort: 7070 },
        onePasswordConnect: { clusterIP: '10.43.82.198', port: 8000 },
        nodeExporter: { textfileDir: '/var/lib/node-exporter/textfile' },
      },
    );
  }).toThrowWithMessage(
    Error,
    'exposure entry tailscale has port 41642, but tailnet.directPort is 41641\n' +
      'exposure entry k3s-api has port 6444, but k3s.apiPort is 6443\n' +
      'exposure entry grafana has port undefined, but k3s.grafanaNodePort is 30300',
  );
});
