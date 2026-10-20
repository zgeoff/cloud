import { expect, test } from 'bun:test';
import { join } from 'node:path';
import { buildNetworkPolicyManifests } from './build-network-policy-manifests.ts';

test('it matches the copy that the NixOS check applies, which bun run write:network-policies writes', async () => {
  const committed: unknown = await Bun.file(
    join(import.meta.dir, '..', '..', 'nixos', 'checks', 'network-policies.json'),
  ).json();

  expect(committed).toStrictEqual(buildNetworkPolicyManifests());
});

test('it gives every namespace but nixie the egress deny, kube-system and default included', () => {
  expect(
    buildNetworkPolicyManifests()
      .filter((manifest) => manifest.metadata.name === 'egress-deny')
      .map((manifest) => manifest.metadata.namespace),
  ).toStrictEqual([
    'atc',
    'default',
    'files',
    'ingress',
    'kube-node-lease',
    'kube-public',
    'kube-system',
    'nixie-ingress',
    'observability',
    'onepassword',
  ]);
});

test('it places each allow in the namespace of the pods it selects', () => {
  expect(
    buildNetworkPolicyManifests()
      .filter((manifest) => manifest.metadata.name !== 'egress-deny')
      .map((manifest) => [manifest.metadata.namespace, manifest.metadata.name]),
  ).toStrictEqual([
    ['atc', 'atc-gateway-egress'],
    ['observability', 'atc-daemon-probe-egress'],
    ['observability', 'imp-health-probe-egress'],
    ['ingress', 'cloudflared-egress'],
  ]);
});
