import { findAlertURL } from './find-alert-url.ts';
import { findVariable } from './find-variable.ts';
import { loadClusterInputs } from './load-cluster-inputs.ts';
import { requireAlertWebhook } from './require-alert-webhook.ts';
import { requireCloudflareAccountID } from './require-cloudflare-account-id.ts';
import type { AlertWebhook, Environment, StackConfig } from './types.ts';

type ClusterInputs = NonNullable<ReturnType<typeof loadClusterInputs>> & {
  readonly alertWebhook: AlertWebhook | undefined;
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
            alertWebhook: requireAlertWebhook(
              config.getBoolean('discordAlerts') ?? false,
              alertURL,
              findVariable(env, 'ALERT_MENTION_USER_ID')?.trim(),
            ),
          },
        }),
  };
}
