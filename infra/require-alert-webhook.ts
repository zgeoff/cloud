// The Discord webhook for in-cluster alerts, or undefined while the receiver is gated off.
// Turned on with `pulumi config set discordAlerts true`; then a missing ALERT_WEBHOOK_URL
// throws, so the flag never deploys an Alertmanager that silently cannot deliver.
export function requireAlertWebhook(
  enabled: boolean,
  webhookURL: string | undefined,
): string | undefined {
  if (!enabled) {
    return undefined;
  }

  if (webhookURL === undefined || webhookURL.trim() === '') {
    throw new Error(
      'discordAlerts is on, but ALERT_WEBHOOK_URL is empty; run through `op run --env-file=../.env`',
    );
  }

  return webhookURL;
}
