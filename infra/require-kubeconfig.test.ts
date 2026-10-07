import { expect, test } from 'bun:test';
import { requireKubeconfig } from './require-kubeconfig.ts';

test('it returns the kubeconfig when the cluster is managed', () => {
  expect(requireKubeconfig('managed', 'apiVersion: v1')).toBe('apiVersion: v1');
});

test('it returns the kubeconfig untrimmed', () => {
  expect(requireKubeconfig('managed', '  apiVersion: v1\n')).toBe('  apiVersion: v1\n');
});

test.each([
  ['missing', undefined],
  ['empty', ''],
  ['blank', '  \n'],
])('it throws when the cluster is managed and the kubeconfig is %s', (_kind, kubeconfig) => {
  expect(() => requireKubeconfig('managed', kubeconfig)).toThrowWithMessage(
    Error,
    'cluster is managed, but K3S_KUBECONFIG is empty; run through `op run --env-file=../.env`',
  );
});

test.each([
  ['missing', undefined],
  ['set', 'apiVersion: v1'],
])(
  'it leaves the cluster out when the mode is none and the kubeconfig is %s',
  (_kind, kubeconfig) => {
    expect(requireKubeconfig('none', kubeconfig)).toBeUndefined();
  },
);

test('it throws when the mode is unset', () => {
  expect(() => requireKubeconfig(undefined, 'apiVersion: v1')).toThrowWithMessage(
    Error,
    'stack config "cluster" is unset; set it to managed or none',
  );
});

test.each([
  ['Managed', 'stack config "cluster" is "Managed"; set it to managed or none'],
  ['', 'stack config "cluster" is ""; set it to managed or none'],
])('it throws when the mode is the unknown %p', (mode, message) => {
  expect(() => requireKubeconfig(mode, 'apiVersion: v1')).toThrowWithMessage(Error, message);
});
