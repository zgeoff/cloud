import { findVariable } from './find-variable.ts';
import type { Environment } from './types.ts';

export function requireVariable(env: Environment, name: string, need: string): string {
  const value = findVariable(env, name);

  if (value === undefined) {
    throw new Error(`${name} is ${env[name] === undefined ? 'unset' : 'blank'}; ${need}`);
  }

  return value;
}
