import { findAlertURL } from './find-alert-url.ts';
import { loadClusterInputs } from './load-cluster-inputs.ts';
import { requireAlertWebhook } from './require-alert-webhook.ts';
import { requireCloudflareAccountID } from './require-cloudflare-account-id.ts';
import type { Environment, StackConfig } from './types.ts';

type ClusterInputs = NonNullable<ReturnType<typeof loadClusterInputs>> & {
  // Alertmanager's Discord webhook, set only after `pulumi config set discordAlerts true` (#29)
  readonly alertWebhookURL: string | undefined;
};

interface Inputs {
  // the Cloudflare account every Cloudflare resource belongs to
  readonly accountID: string;

  // set once NixOS answers tailnet SSH: attaches the edge firewall and drops public SSH
  readonly hostOnTailnet: boolean;

  // the health-check Worker's alert webhook; without it, state changes show only in its logs
  readonly alertURL: string | undefined;

  // what a managed cluster needs; unset while "cluster" leaves it out
  readonly cluster?: ClusterInputs;
}

// Every stack config value and env variable the program reads, checked before any resource
// registers. index.ts builds Config and the env once and passes them here; nothing else reads
// either. A missing cluster secret fails here instead of planning to delete the cluster.
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
