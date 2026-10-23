import type { AlertWebhook } from './types.ts';

// Discord's IDs are snowflakes: decimal integers
const discordIDPattern = /^[0-9]+$/u;

export function requireAlertWebhook(
  enabled: boolean,
  alertURL: string | undefined,
  mentionUserID: string | undefined,
): AlertWebhook | undefined {
  if (!enabled) {
    return undefined;
  }

  // so the flag never deploys an Alertmanager that silently cannot deliver
  if (alertURL === undefined) {
    throw new Error(
      'discordAlerts is on, but ALERT_WEBHOOK_URL is empty; run through `op run --env-file=../.env`',
    );
  }

  if (mentionUserID === undefined) {
    throw new Error(
      'discordAlerts is on, but ALERT_MENTION_USER_ID is empty; run through `op run --env-file=../.env`',
    );
  }

  // Alertmanager reads the ID as template text, so only digits may reach it
  if (!discordIDPattern.test(mentionUserID)) {
    throw new Error('ALERT_MENTION_USER_ID is not a Discord user ID: it holds a non-digit');
  }

  return { url: alertURL, mentionUserID };
}
