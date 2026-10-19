import { expect, test } from 'bun:test';
import { buildNamespaceMetadata } from './build-namespace-metadata.ts';
import type { ClusterNamespace } from './cluster-namespaces.ts';
import { clusterNamespaces } from './cluster-namespaces.ts';

test('it gives every namespace but observability and kube-system the baseline warn and audit labels', () => {
  const labelled = (Object.keys(clusterNamespaces) as ClusterNamespace[]).filter(
    (name) => name !== 'observability' && name !== 'kube-system',
  );

  expect(labelled.map((name) => buildNamespaceMetadata(name))).toSatisfyAll(
    (metadata: ReturnType<typeof buildNamespaceMetadata>) =>
      metadata.labels?.['pod-security.kubernetes.io/warn'] === 'baseline' &&
      metadata.labels['pod-security.kubernetes.io/audit'] === 'baseline',
  );
});

test('it names a namespace and gives it the baseline warn and audit labels', () => {
  expect(buildNamespaceMetadata('nixie')).toStrictEqual({
    name: 'nixie',
    labels: {
      'pod-security.kubernetes.io/audit': 'baseline',
      'pod-security.kubernetes.io/warn': 'baseline',
    },
  });
});

test.each([['observability'], ['kube-system']] as const)(
  'it gives %s no Pod Security label',
  (name) => {
    expect(buildNamespaceMetadata(name)).toStrictEqual({ name });
  },
);
