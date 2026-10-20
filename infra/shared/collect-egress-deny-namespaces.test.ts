import { expect, test } from 'bun:test';
import { collectEgressDenyNamespaces } from './collect-egress-deny-namespaces.ts';

test('it collects every namespace in the cluster but nixie, kube-system and default included', () => {
  expect(collectEgressDenyNamespaces()).toStrictEqual([
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
