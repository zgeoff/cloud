export function requireAlertWebhook(
  enabled: boolean,
  alertURL: string | undefined,
): string | undefined {
  if (!enabled) {
    return undefined;
  }

  // so the flag never deploys an Alertmanager that silently cannot deliver
  if (alertURL === undefined) {
    throw new Error(
      'discordAlerts is on, but ALERT_WEBHOOK_URL is empty; run through `op run --env-file=../.env`',
    );
  }

  return alertURL;
}
