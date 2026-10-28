import { buildGitHubClient } from './build-github-client.ts';
import { buildImpdClient } from './build-impd-client.ts';
import { buildSpendProxyIO } from './build-spend-proxy-io.ts';
import { createPreviewStore } from './create-preview-store.ts';
import { createSpendProxies } from './create-spend-proxies.ts';
import type { PreviewConfig } from './load-preview-config.ts';
import { makeLinkHandler } from './make-link-handler.ts';
import { makeSlotLock } from './make-slot-lock.ts';
import { makeSpendHandler } from './make-spend-handler.ts';
import { makeWebhookHandler } from './make-webhook-handler.ts';
import { runContractRetries } from './run-contract-retries.ts';
import { runIdleSweep } from './run-idle-sweep.ts';
import type { PreviewDeps } from './types.ts';

export function startPreviewService(config: PreviewConfig): { readonly stop: () => Promise<void> } {
  const store = createPreviewStore(config.databasePath);

  // a boot runs only inside the process that started it, so none survives a restart
  const interrupted = store.updateInterruptedBoots();

  // so does a contract run, which the first retry starts over
  const requeued = store.updateInterruptedContractRuns();

  const spendProxies =
    config.spend === null
      ? null
      : createSpendProxies(config.spend.settings, {
          now: readNow,
          log: writeLog,
          io: buildSpendProxyIO(),
        });

  const deps: PreviewDeps = {
    settings: config.settings,
    spendProxies,
    store,
    impd: buildImpdClient(config.impdURL, config.impdToken),
    github: buildGitHubClient('https://api.github.com', config.githubApp, () => new Date()),
    webhookSecret: config.webhookSecret,
    pendingBoots: new Set(),
    pendingRuns: new Set(),
    withSlotLock: makeSlotLock(),
    now: readNow,
    sleep: (durationMs) => Bun.sleep(durationMs),
    log: writeLog,
  };

  // two listeners, so the public route reaches the webhook alone: the link listener on the tailnet,
  // and the webhook listener that the cluster's tunnel dials
  const linkServer = Bun.serve({ ...config.linkListener, fetch: makeLinkHandler(deps) });
  const webhookServer = Bun.serve({ ...config.webhookListener, fetch: makeWebhookHandler(deps) });

  // a third on the docker bridge, which imp-host's broker dials with each preview's model calls; a
  // streamed reply can sit quiet for longer than Bun's idle timeout while the model thinks
  const spendServer =
    config.spend === null || spendProxies === null
      ? null
      : Bun.serve({
          ...config.spend.listener,
          idleTimeout: 0,
          fetch: makeSpendHandler({
            store,
            proxies: spendProxies,
            sendRequest: fetch,
            log: writeLog,
          }),
        });

  const sweep = setInterval(() => {
    void runIdleSweep(deps);
    void spendProxies?.removeIdle();
    runContractRetries(deps);
  }, config.sweepIntervalMs);

  deps.log(`previews: the last stop failed ${interrupted} boots and requeued ${requeued} runs`);

  deps.log(
    `previews: links on ${config.linkListener.hostname}:${config.linkListener.port}, webhook on ${config.webhookListener.hostname}:${config.webhookListener.port}`,
  );

  if (config.spend !== null) {
    deps.log(
      `previews: model routes on ${config.spend.listener.hostname}:${config.spend.listener.port}, $${config.spend.settings.limitDollars} each`,
    );
  }

  return {
    stop: async () => {
      clearInterval(sweep);

      await Promise.all([linkServer.stop(), webhookServer.stop(), spendServer?.stop()]);
      await Promise.allSettled([...deps.pendingBoots, ...deps.pendingRuns]);
      await spendProxies?.removeAll();

      store.close();
    },
  };
}

function readNow(): Date {
  return new Date();
}

function writeLog(line: string): void {
  console.log(line);
}
