import { expect, test } from 'bun:test';
import { collectK3sLabelledNamespaces } from './collect-k3s-labelled-namespaces.ts';

test('it collects the namespaces k3s creates, leaving out kube-system', () => {
  expect(collectK3sLabelledNamespaces()).toStrictEqual([
    'default',
    'kube-node-lease',
    'kube-public',
  ]);
});
