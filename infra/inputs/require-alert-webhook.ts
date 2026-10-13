// The Discord webhook for in-cluster alerts (findAlertURL's value), or undefined while the
// receiver is gated off. With discordAlerts on, a missing ALERT_WEBHOOK_URL throws, so the flag
// never deploys an Alertmanager that silently cannot deliver.
export function requireAlertWebhook(
  enabled: boolean,
  alertURL: string | undefined,
): string | undefined {
  if (!enabled) {
    return undefined;
  }

  if (alertURL === undefined) {
    throw new Error(
      'discordAlerts is on, but ALERT_WEBHOOK_URL is empty; run through `op run --env-file=../.env`',
    );
  }

  return alertURL;
}
