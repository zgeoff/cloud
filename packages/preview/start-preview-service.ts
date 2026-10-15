import { buildGitHubClient } from './build-github-client.ts';
import { buildImpdClient } from './build-impd-client.ts';
import { createPreviewStore } from './create-preview-store.ts';
import type { PreviewConfig } from './load-preview-config.ts';
import { makeLinkHandler } from './make-link-handler.ts';
import { makeSlotLock } from './make-slot-lock.ts';
import { makeWebhookHandler } from './make-webhook-handler.ts';
import { runIdleSweep } from './run-idle-sweep.ts';
import type { PreviewDeps } from './types.ts';

// Two listeners, so the public route reaches the webhook alone: the link listener on the tailnet,
// and the webhook listener that the cluster's tunnel dials. The idle sweep runs on a timer.
export function startPreviewService(config: PreviewConfig): { readonly stop: () => Promise<void> } {
  const store = createPreviewStore(config.databasePath);

  // a boot runs only inside the process that started it, so none survives a restart
  const interrupted = store.updateInterruptedBoots();

  const deps: PreviewDeps = {
    settings: config.settings,
    store,
    impd: buildImpdClient(config.impdURL, config.impdToken),
    github: buildGitHubClient('https://api.github.com', config.githubToken),
    webhookSecret: config.webhookSecret,
    pendingBoots: new Set(),
    withSlotLock: makeSlotLock(),
    now: () => new Date(),
    sleep: (ms) => Bun.sleep(ms),
    log: (line) => {
      console.log(line);
    },
  };

  const linkServer = Bun.serve({ ...config.linkListener, fetch: makeLinkHandler(deps) });
  const webhookServer = Bun.serve({ ...config.webhookListener, fetch: makeWebhookHandler(deps) });

  const sweep = setInterval(() => {
    void runIdleSweep(deps);
  }, config.sweepIntervalMs);

  deps.log(`previews: ${interrupted} boots failed by the last stop`);

  deps.log(
    `previews: links on ${config.linkListener.hostname}:${config.linkListener.port}, webhook on ${config.webhookListener.hostname}:${config.webhookListener.port}`,
  );

  return {
    stop: async () => {
      clearInterval(sweep);

      await Promise.all([linkServer.stop(), webhookServer.stop()]);
      await Promise.allSettled(deps.pendingBoots);

      store.close();
    },
  };
}
