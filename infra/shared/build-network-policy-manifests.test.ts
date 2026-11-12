import { expect, test } from 'bun:test';
import { join } from 'node:path';
import { z } from 'zod';
import { buildNetworkPolicyManifests } from './build-network-policy-manifests.ts';

test('it matches the copy that the NixOS check applies, which bun run write:network-policies writes', async () => {
  const committed: unknown = await Bun.file(
    join(import.meta.dir, '..', '..', 'nixos', 'checks', 'network-policies.json'),
  ).json();

  expect(committed).toStrictEqual(buildNetworkPolicyManifests());
});

test('it gives every namespace the egress deny, kube-system and default included', () => {
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
    'nixie',
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
    ['nixie', 'nixie-egress'],
    ['nixie', 'nixie-sandbox-images-egress'],
    ['ingress', 'cloudflared-egress'],
    ['pepys', 'egress-deny-all'],
    ['pepys', 'pepys-garage-egress'],
    ['pepys', 'pepys-s2-egress'],
    ['pepys', 'pepys-ingest-egress'],
    ['pepys', 'pepys-host-egress'],
    ['pepys', 'pepys-backup-egress'],
  ]);
});

test('it gives the pepys namespace no egress rule without a destination and a port', () => {
  const pepys = buildNetworkPolicyManifests().filter(
    (manifest) => manifest.metadata.namespace === 'pepys',
  );

  const rules = pepys.flatMap((manifest) => z.array(z.unknown()).parse(manifest.spec.egress ?? []));

  const hasDestinationAndPort = z.object({
    to: z.array(z.unknown()).min(1),
    ports: z.array(z.unknown()).min(1),
  });

  expect(pepys.map((manifest) => manifest.metadata.name)).toContain('egress-deny-all');
  expect(rules.length).toBeGreaterThan(0);
  expect(rules.filter((rule) => !hasDestinationAndPort.safeParse(rule).success)).toStrictEqual([]);
});
