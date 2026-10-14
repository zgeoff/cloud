import type { Provider } from '@pulumi/kubernetes';
import type { Namespace } from '@pulumi/kubernetes/core/v1';
import { Secret } from '@pulumi/kubernetes/core/v1';
import { secret } from '@pulumi/pulumi';

const secretName = 'alertmanager-discord';
const key = 'webhook-url';

interface AlertWebhook {
  readonly resource: Secret;
  readonly secretName: string;
  readonly file: string;
}

// The Discord webhook as a Secret beside Alertmanager, which mounts it at
// /etc/alertmanager/secrets/<name>/<key> (#29). It exists only while discordAlerts is on.
export function createAlertWebhook(
  ns: Namespace,
  webhookURL: string,
  cluster: Provider,
): AlertWebhook {
  const resource = new Secret(
    'alertmanager-discord',
    {
      metadata: { name: secretName, namespace: ns.metadata.name },
      stringData: { [key]: secret(webhookURL) },
    },
    { provider: cluster },
  );

  return { resource, secretName, file: `/etc/alertmanager/secrets/${secretName}/${key}` };
}
