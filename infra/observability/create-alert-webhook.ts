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

  // Alertmanager mounts the Secret at /etc/alertmanager/secrets/<name>/<key>.
  return { resource, secretName, file: `/etc/alertmanager/secrets/${secretName}/${key}` };
}
