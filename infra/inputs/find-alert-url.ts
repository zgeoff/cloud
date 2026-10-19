import { findVariable } from './find-variable.ts';
import type { Environment } from './types.ts';

export function findAlertURL(env: Environment): string | undefined {
  return findVariable(env, 'ALERT_WEBHOOK_URL')?.trim();
}
