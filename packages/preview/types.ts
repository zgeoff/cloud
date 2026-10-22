import type { GitHubClient } from './build-github-client.ts';
import type { ImpdClient } from './build-impd-client.ts';
import type { PreviewStore } from './create-preview-store.ts';
import type { SpendProxies } from './create-spend-proxies.ts';

export interface PreviewSettings {
  readonly baseURL: string;

  // owner/name of each repository whose pull requests get previews, or owner/* for every
  // repository of an owner
  readonly repos: ReadonlySet<string>;

  readonly slots: number;

  readonly idleMs: number;

  // impd's HTTPS domain, under which each imp answers at https://<name>.<domain>
  readonly impDomain: string;
  readonly impImage: string;
  readonly impMemoryMib: number;

  // the impd secret the service grants each preview imp, so its clone goes through the broker;
  // null clones without a credential, which reaches public repositories only
  readonly impGitHubSecret: string | null;

  // the impd secret, for the model API's host, that the service grants each preview imp, so the
  // stack's model calls go through the broker; null leaves the stack without a model route
  readonly impModelSecret: string | null;

  readonly buildTimeoutMs: number;

  readonly healthTimeoutMs: number;
  readonly healthPollMs: number;

  readonly contract: ContractSettings | null;
}

export interface ContractSettings {
  readonly repos: ReadonlySet<string>;

  // the impd secret that carries the model credential, which the broker adds to each request the
  // suite sends to the model's API
  readonly modelSecret: string;

  readonly timeoutMs: number;
}

export interface SpendSettings {
  // the counting proxy's binary, which the service starts once for each preview
  readonly proxyPath: string;

  // each preview's proxy config and counter store
  readonly directory: string;

  // the model API's origin, which each proxy sends a preview's model calls to
  readonly upstream: string;

  // the one model each preview may call, priced per million tokens with the proxy's price keys
  readonly model: string;
  readonly prices: SpendPrices;

  // the dollars a preview may spend over its pull request's life
  readonly limitDollars: number;

  // how long a proxy goes unused before the service stops it; its count stays on disk
  readonly idleMs: number;
}

export interface SpendPrices {
  readonly input: number;
  readonly cache_write: number;
  readonly cache_write_1h: number;
  readonly cached_input: number;
  readonly output: number;
}

export interface PreviewDeps {
  readonly settings: PreviewSettings;

  // the counting proxies on each preview's model route; null runs the previews without a spend cap
  readonly spendProxies: SpendProxies | null;
  readonly store: PreviewStore;
  readonly impd: ImpdClient;
  readonly github: GitHubClient;
  readonly webhookSecret: string;

  // the boots in flight, which a caller awaits to know the service is idle
  readonly pendingBoots: Set<Promise<void>>;

  // the SDK contract runs in flight, apart from the boots, because the link waits on a boot alone
  readonly pendingRuns: Set<Promise<void>>;

  readonly withSlotLock: <T>(run: () => Promise<T>) => Promise<T>;
  readonly now: () => Date;
  readonly sleep: (durationMs: number) => Promise<void>;
  readonly log: (line: string) => void;
}
