import type { Environment } from './types.ts';

export function findVariable(env: Environment, name: string): string | undefined {
  const value = env[name];

  // untrimmed, since a kubeconfig or a key file keeps its own whitespace
  return value === undefined || value.trim() === '' ? undefined : value;
}
