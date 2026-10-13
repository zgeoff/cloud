import { findVariable } from './find-variable.ts';
import type { Environment } from './types.ts';

// ALERT_WEBHOOK_URL, read once for both its readers: Alertmanager's Discord receiver and the
// health-check Worker. Trimmed, and undefined when unset or blank.
export function findAlertURL(env: Environment): string | undefined {
  return findVariable(env, 'ALERT_WEBHOOK_URL')?.trim();
}
