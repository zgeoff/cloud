// each test asserts the whole rule list as one literal, so its body is long
/* oxlint-disable max-lines-per-function */
import { expect, test } from 'bun:test';
import { output } from '@pulumi/pulumi';
import { buildEdgeRules } from './build-edge-rules.ts';

test('it opens public SSH, Tailscale and ICMP on both families before the host is on the tailnet', () => {
  const firewallID = output('fw-0a1b2c3d');

  expect(buildEdgeRules({ hostOnTailnet: false, firewallID })).toStrictEqual([
    {
      name: 'edge-ssh-v4',
      args: {
        firewallId: firewallID,
        protocol: 'tcp',
        port: '22',
        subnet: '0.0.0.0',
        subnetSize: 0,
        description: 'SSH, until tailnet SSH (#6)',
      },
    },
    {
      name: 'edge-ssh-v6',
      args: {
        firewallId: firewallID,
        protocol: 'tcp',
        port: '22',
        subnet: '::',
        subnetSize: 0,
        description: 'SSH, until tailnet SSH (#6)',
      },
    },
    {
      name: 'edge-tailscale-v4',
      args: {
        firewallId: firewallID,
        protocol: 'udp',
        port: '41641',
        subnet: '0.0.0.0',
        subnetSize: 0,
        description: 'Tailscale direct connections',
      },
    },
    {
      name: 'edge-tailscale-v6',
      args: {
        firewallId: firewallID,
        protocol: 'udp',
        port: '41641',
        subnet: '::',
        subnetSize: 0,
        description: 'Tailscale direct connections',
      },
    },
    {
      name: 'edge-icmp-v4',
      args: {
        firewallId: firewallID,
        protocol: 'icmp',
        subnet: '0.0.0.0',
        subnetSize: 0,
        description: 'ICMP',
      },
    },
    {
      name: 'edge-icmp-v6',
      args: {
        firewallId: firewallID,
        protocol: 'icmp',
        subnet: '::',
        subnetSize: 0,
        description: 'ICMP',
      },
    },
  ]);
});

test('it drops public SSH and keeps Tailscale and ICMP on both families once the host is on the tailnet', () => {
  const firewallID = output('fw-0a1b2c3d');

  expect(buildEdgeRules({ hostOnTailnet: true, firewallID })).toStrictEqual([
    {
      name: 'edge-tailscale-v4',
      args: {
        firewallId: firewallID,
        protocol: 'udp',
        port: '41641',
        subnet: '0.0.0.0',
        subnetSize: 0,
        description: 'Tailscale direct connections',
      },
    },
    {
      name: 'edge-tailscale-v6',
      args: {
        firewallId: firewallID,
        protocol: 'udp',
        port: '41641',
        subnet: '::',
        subnetSize: 0,
        description: 'Tailscale direct connections',
      },
    },
    {
      name: 'edge-icmp-v4',
      args: {
        firewallId: firewallID,
        protocol: 'icmp',
        subnet: '0.0.0.0',
        subnetSize: 0,
        description: 'ICMP',
      },
    },
    {
      name: 'edge-icmp-v6',
      args: {
        firewallId: firewallID,
        protocol: 'icmp',
        subnet: '::',
        subnetSize: 0,
        description: 'ICMP',
      },
    },
  ]);
});
