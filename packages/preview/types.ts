import type { GitHubClient } from './build-github-client.ts';
import type { ImpdClient } from './build-impd-client.ts';
import type { PreviewStore } from './create-preview-store.ts';

export interface PreviewSettings {
  // the link's origin on the tailnet, such as http://geoffcloud:8417
  readonly baseURL: string;

  // owner/name of each repository whose pull requests get previews, or owner/* for an owner's
  readonly repos: ReadonlySet<string>;

  // how many previews run at once
  readonly slots: number;

  // how long a running preview goes unused before the service puts it to sleep
  readonly idleMs: number;

  // impd's HTTPS domain, under which each imp answers at https://<name>.<domain>
  readonly impDomain: string;
  readonly impImage: string;
  readonly impMemoryMib: number;

  // the impd secret the service grants each preview imp, so its clone goes through the broker;
  // null clones without a credential, which reaches public repositories only
  readonly impGitHubSecret: string | null;

  // how long the build, the checkout and `docker compose up`, may run before the boot fails
  readonly buildTimeoutMs: number;

  // how long a boot waits for the health path to answer
  readonly healthTimeoutMs: number;
  readonly healthPollMs: number;

  // the SDK contract run, or null when no repository has one
  readonly contract: ContractSettings | null;
}

export interface ContractSettings {
  // owner/name of each repository whose pull requests run the SDK contract suite when they change
  // the Agent SDK's pin
  readonly repos: ReadonlySet<string>;

  // the impd secret that carries the model credential, which the broker adds to each request the
  // suite sends to the model's API
  readonly modelSecret: string;

  // how long one run may take, from the start of its guest command to its last test
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

  // runs the slot rule and the start of an imp as one step, one open at a time
  readonly withSlotLock: <T>(run: () => Promise<T>) => Promise<T>;
  readonly now: () => Date;
  readonly sleep: (ms: number) => Promise<void>;
  readonly log: (line: string) => void;
}
