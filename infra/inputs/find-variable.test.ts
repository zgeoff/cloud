import { expect, test } from 'bun:test';
import { findVariable } from './find-variable.ts';

test('it returns a set value as given, whitespace included', () => {
  expect(findVariable({ K3S_KUBECONFIG: 'apiVersion: v1\n' }, 'K3S_KUBECONFIG')).toBe(
    'apiVersion: v1\n',
  );
});

test('it reads an unset variable as undefined', () => {
  expect(findVariable({}, 'K3S_KUBECONFIG')).toBeUndefined();
});

test.each([
  ['empty', ''],
  ['only spaces', '   '],
  ['only a newline', '\n'],
])('it reads a value that is %s as undefined', (_kind, value) => {
  expect(findVariable({ K3S_KUBECONFIG: value }, 'K3S_KUBECONFIG')).toBeUndefined();
});
