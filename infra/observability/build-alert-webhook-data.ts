import type { AlertWebhook } from '../inputs/index.ts';
import { buildSecretChecksum } from './build-secret-checksum.ts';
import { renderMentionTemplate } from './render-mention-template.ts';

interface AlertWebhookData {
  readonly data: Readonly<Record<string, string>>;
  readonly checksum: string;
}

interface AlertWebhookKeys {
  readonly url: string;
  readonly mention: string;
}

export function buildAlertWebhookData(
  webhook: AlertWebhook,
  keys: AlertWebhookKeys,
): AlertWebhookData {
  const data = {
    [keys.url]: webhook.url,
    [keys.mention]: renderMentionTemplate(webhook.mentionUserID),
  };

  // the webhook's random token salts the hash, so the checksum shows nothing of the user's ID
  return { data, checksum: buildSecretChecksum(data) };
}
