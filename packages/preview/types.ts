import type { GitHubClient } from './build-github-client.ts';
import type { ImpdClient } from './build-impd-client.ts';
import type { PreviewStore } from './create-preview-store.ts';

export interface PreviewSettings {
  readonly baseURL: string;

  // owner/name of each repository whose pull requests get previews, or owner/* for an owner's
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

export interface PreviewDeps {
  readonly settings: PreviewSettings;
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
