import type { Provider } from '@pulumi/kubernetes';
import type { Namespace } from '@pulumi/kubernetes/core/v1';
import { Secret } from '@pulumi/kubernetes/core/v1';
import { secret } from '@pulumi/pulumi';
import type { AlertWebhook } from '../inputs/index.ts';
import { renderMentionTemplate } from './render-mention-template.ts';

const secretName = 'alertmanager-discord';
const urlKey = 'webhook-url';
const mentionKey = 'mention.tmpl';

interface AlertWebhookResource {
  readonly resource: Secret;
  readonly secretName: string;
  readonly file: string;
  readonly mentionTemplateFile: string;
}

export function createAlertWebhook(
  ns: Namespace,
  webhook: AlertWebhook,
  cluster: Provider,
): AlertWebhookResource {
  const resource = new Secret(
    'alertmanager-discord',
    {
      metadata: { name: secretName, namespace: ns.metadata.name },
      stringData: {
        [urlKey]: secret(webhook.url),
        [mentionKey]: secret(renderMentionTemplate(webhook.mentionUserID)),
      },
    },

    // The provider replaces a Secret when its data changes, and a create of the fixed name before
    // the delete fails with "already exists".
    { provider: cluster, deleteBeforeReplace: true },
  );

  // Alertmanager mounts the Secret at /etc/alertmanager/secrets/<name>/<key>.
  return {
    resource,
    secretName,
    file: `/etc/alertmanager/secrets/${secretName}/${urlKey}`,
    mentionTemplateFile: `/etc/alertmanager/secrets/${secretName}/${mentionKey}`,
  };
}
