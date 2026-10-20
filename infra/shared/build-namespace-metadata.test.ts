import { expect, test } from 'bun:test';
import { buildNamespaceMetadata } from './build-namespace-metadata.ts';
import { clusterNamespaceNames } from './cluster-namespaces.ts';

test('it gives every namespace but observability, nixie-ingress and kube-system the baseline enforce, warn and audit labels', () => {
  const labelled = clusterNamespaceNames.filter(
    (name) => name !== 'observability' && name !== 'nixie-ingress' && name !== 'kube-system',
  );

  expect(labelled.map((name) => buildNamespaceMetadata(name))).toSatisfyAll(
    (metadata: ReturnType<typeof buildNamespaceMetadata>) =>
      metadata.labels?.['pod-security.kubernetes.io/enforce'] === 'baseline' &&
      metadata.labels['pod-security.kubernetes.io/warn'] === 'baseline' &&
      metadata.labels['pod-security.kubernetes.io/audit'] === 'baseline',
  );
});

test('it names a namespace and gives it the baseline enforce, warn and audit labels', () => {
  expect(buildNamespaceMetadata('nixie')).toStrictEqual({
    name: 'nixie',
    labels: {
      'pod-security.kubernetes.io/audit': 'baseline',
      'pod-security.kubernetes.io/enforce': 'baseline',
      'pod-security.kubernetes.io/warn': 'baseline',
    },
  });
});

test.each([['observability'], ['nixie-ingress'], ['kube-system']] as const)(
  'it gives %s no Pod Security label',
  (name) => {
    expect(buildNamespaceMetadata(name)).toStrictEqual({ name });
  },
);
