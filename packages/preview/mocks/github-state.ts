export interface StoredComment {
  readonly id: number;

  readonly author: string;
  readonly repo: string;
  readonly number: number;
  body: string;
}

export const composeFiles = new Map<string, string>();
export const issueComments: StoredComment[] = [];

// GitHub's pull request files API leaves `patch` out of a file whose diff is too large to show
export interface StoredPullRequestFile {
  readonly filename: string;
  readonly patch?: string;
}

export const pullRequestFiles = new Map<string, StoredPullRequestFile[]>();

export interface StoredCommitStatus {
  readonly repo: string;
  readonly sha: string;
  readonly state: string;
  readonly context: string;
  readonly description: string;
}

// every status posted, in order, as GitHub keeps each one rather than replacing the last
export const commitStatuses: StoredCommitStatus[] = [];

export interface StoredInstallationToken {
  readonly token: string;

  // the repositories the token reaches, as owner/name
  readonly repos: readonly string[];
  readonly expiresAt: Date;
}

// every installation token minted, in order
export const installationTokens: StoredInstallationToken[] = [];

// the stand-in App is installed on every repository but these
export const uninstalledRepos = new Set<string>();
