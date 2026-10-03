import { describe, expect, test } from 'bun:test';
import { requireKubeconfig } from './require-kubeconfig.ts';

describe('requireKubeconfig', () => {
  test('returns the kubeconfig when the cluster is managed', () => {
    expect(requireKubeconfig('managed', 'apiVersion: v1')).toBe('apiVersion: v1');
  });

  test('throws when the cluster is managed and the kubeconfig is missing', () => {
    expect(() => requireKubeconfig('managed', undefined)).toThrow('K3S_KUBECONFIG is empty');
  });

  test('throws when the cluster is managed and the kubeconfig is blank', () => {
    expect(() => requireKubeconfig('managed', '')).toThrow('K3S_KUBECONFIG is empty');
    expect(() => requireKubeconfig('managed', '  \n')).toThrow('K3S_KUBECONFIG is empty');
  });

  test('leaves the cluster out only when the mode says none', () => {
    expect(requireKubeconfig('none', undefined)).toBeUndefined();
    expect(requireKubeconfig('none', 'apiVersion: v1')).toBeUndefined();
  });

  test('throws when the mode is unset or unknown', () => {
    expect(() => requireKubeconfig(undefined, 'apiVersion: v1')).toThrow('"cluster" is unset');
    expect(() => requireKubeconfig('Managed', 'apiVersion: v1')).toThrow('"cluster" is "Managed"');
  });
});
