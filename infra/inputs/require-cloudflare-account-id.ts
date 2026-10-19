import { requireVariable } from './require-variable.ts';
import type { Environment } from './types.ts';

export function requireCloudflareAccountID(env: Environment): string {
  return requireVariable(env, 'CLOUDFLARE_ACCOUNT_ID', 'run through `op run --env-file=../.env`');
}
