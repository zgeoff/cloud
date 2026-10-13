import type { Environment } from './types.ts';

// The one env check: a variable's value, or undefined when it is unset or holds only whitespace.
// The value comes back as given, since a kubeconfig or a key file keeps its own whitespace.
export function findVariable(env: Environment, name: string): string | undefined {
  const value = env[name];

  return value === undefined || value.trim() === '' ? undefined : value;
}
