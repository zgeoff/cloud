import { requireVariable } from './require-variable.ts';
import type { Environment } from './types.ts';

// The Cloudflare account every Cloudflare resource belongs to, from CLOUDFLARE_ACCOUNT_ID.
// Unset or blank, it throws before any resource registers.
export function requireCloudflareAccountID(env: Environment): string {
  return requireVariable(env, 'CLOUDFLARE_ACCOUNT_ID', 'run through `op run --env-file=../.env`');
}
