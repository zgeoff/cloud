import type { Provider } from '@pulumi/kubernetes';
import type { Namespace } from '@pulumi/kubernetes/core/v1';
import { Secret } from '@pulumi/kubernetes/core/v1';
import { secret } from '@pulumi/pulumi';
import type { AlertWebhook } from '../inputs/index.ts';
import { buildAlertWebhookData } from './build-alert-webhook-data.ts';

const secretName = 'alertmanager-discord';
const keys = { url: 'webhook-url', mention: 'mention.tmpl' };

interface AlertWebhookResource {
  readonly resource: Secret;
  readonly secretName: string;
  readonly file: string;
  readonly mentionTemplateFile: string;
  readonly checksum: string;
}

export function createAlertWebhook(
  ns: Namespace,
  webhook: AlertWebhook,
  cluster: Provider,
): AlertWebhookResource {
  const built = buildAlertWebhookData(webhook, keys);

  const resource = new Secret(
    'alertmanager-discord',
    {
      metadata: { name: secretName, namespace: ns.metadata.name },
      stringData: secret(built.data),
    },

    // The provider replaces a Secret when its data changes, and a create of the fixed name before
    // the delete fails with "already exists".
    { provider: cluster, deleteBeforeReplace: true },
  );

  // Alertmanager mounts the Secret at /etc/alertmanager/secrets/<name>/<key>.
  return {
    resource,
    secretName,
    file: `/etc/alertmanager/secrets/${secretName}/${keys.url}`,
    mentionTemplateFile: `/etc/alertmanager/secrets/${secretName}/${keys.mention}`,
    checksum: built.checksum,
  };
}
