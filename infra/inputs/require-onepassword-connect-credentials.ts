import { findVariable } from './find-variable.ts';
import type { Environment } from './types.ts';

export function requireOnePasswordConnectCredentials(env: Environment): string {
  const value = findVariable(env, 'ONEPASSWORD_CONNECT_CREDENTIALS');

  // a missing value would otherwise plan to delete Connect
  if (value === undefined) {
    throw new Error(
      'cluster is managed, but ONEPASSWORD_CONNECT_CREDENTIALS is empty; run through `op run --env-file=../.env`',
    );
  }

  if (!isJSONObject(value)) {
    throw new Error('ONEPASSWORD_CONNECT_CREDENTIALS is not a JSON object');
  }

  return value;
}

function isJSONObject(value: string): boolean {
  try {
    const parsed: unknown = JSON.parse(value);

    return typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed);
  } catch {
    return false;
  }
}
