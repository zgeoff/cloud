import { findAlertURL } from './find-alert-url.ts';
import { loadClusterInputs } from './load-cluster-inputs.ts';
import { requireAlertWebhook } from './require-alert-webhook.ts';
import { requireCloudflareAccountID } from './require-cloudflare-account-id.ts';
import type { Environment, StackConfig } from './types.ts';

type ClusterInputs = NonNullable<ReturnType<typeof loadClusterInputs>> & {
  readonly alertWebhookURL: string | undefined;
};

interface Inputs {
  readonly accountID: string;

  readonly hostOnTailnet: boolean;

  readonly alertURL: string | undefined;

  readonly cluster?: ClusterInputs;
}

export function loadInputs(config: StackConfig, env: Environment): Inputs {
  const cluster = loadClusterInputs(config, env);
  const accountID = requireCloudflareAccountID(env);
  const alertURL = findAlertURL(env);

  return {
    accountID,
    hostOnTailnet: config.getBoolean('hostOnTailnet') ?? false,
    alertURL,
    ...(cluster === undefined
      ? {}
      : {
          cluster: {
            ...cluster,
            alertWebhookURL: requireAlertWebhook(
              config.getBoolean('discordAlerts') ?? false,
              alertURL,
            ),
          },
        }),
  };
}
