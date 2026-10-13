import { expect, test } from 'bun:test';
import { requireKubeconfig } from './require-kubeconfig.ts';

test('it returns the kubeconfig when the cluster is managed', () => {
  expect(requireKubeconfig('managed', { K3S_KUBECONFIG: 'apiVersion: v1' })).toBe('apiVersion: v1');
});

test('it returns the kubeconfig untrimmed', () => {
  expect(requireKubeconfig('managed', { K3S_KUBECONFIG: '  apiVersion: v1\n' })).toBe(
    '  apiVersion: v1\n',
  );
});

test.each([
  ['missing', {}],
  ['empty', { K3S_KUBECONFIG: '' }],
  ['blank', { K3S_KUBECONFIG: '  \n' }],
])('it throws when the cluster is managed and the kubeconfig is %s', (_kind, env) => {
  expect(() => requireKubeconfig('managed', env)).toThrowWithMessage(
    Error,
    'cluster is managed, but K3S_KUBECONFIG is empty; run through `op run --env-file=../.env`',
  );
});

test.each([
  ['missing', {}],
  ['set', { K3S_KUBECONFIG: 'apiVersion: v1' }],
])('it leaves the cluster out when the mode is none and the kubeconfig is %s', (_kind, env) => {
  expect(requireKubeconfig('none', env)).toBeUndefined();
});

test('it throws when the mode is unset', () => {
  expect(() =>
    requireKubeconfig(undefined, { K3S_KUBECONFIG: 'apiVersion: v1' }),
  ).toThrowWithMessage(Error, 'stack config "cluster" is unset; set it to managed or none');
});

test.each([
  ['Managed', 'stack config "cluster" is "Managed"; set it to managed or none'],
  ['', 'stack config "cluster" is ""; set it to managed or none'],
])('it throws when the mode is the unknown %p', (mode, message) => {
  expect(() => requireKubeconfig(mode, { K3S_KUBECONFIG: 'apiVersion: v1' })).toThrowWithMessage(
    Error,
    message,
  );
});
