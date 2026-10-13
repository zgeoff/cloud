import { findVariable } from './find-variable.ts';
import type { Environment } from './types.ts';

// A variable's value, through the one env check; an unset or blank value throws before any
// resource registers. `need` says who needs the variable or how to set it. The error never
// carries the value.
export function requireVariable(env: Environment, name: string, need: string): string {
  const value = findVariable(env, name);

  if (value === undefined) {
    throw new Error(`${name} is ${env[name] === undefined ? 'unset' : 'blank'}; ${need}`);
  }

  return value;
}
