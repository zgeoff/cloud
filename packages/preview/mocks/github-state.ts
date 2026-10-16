// The in-memory GitHub that the MSW handlers serve: each repository's preview/compose.yaml by
// commit, each pull request's changed files, every issue comment and every commit status. The
// preload clears them after each test.
export interface StoredComment {
  readonly id: number;

  // the login of the comment's author
  readonly author: string;
  readonly repo: string;
  readonly number: number;
  body: string;
}

// the login GitHub answers for the service's token, which authors each comment the service posts
export const tokenLogin = 'preview-bot';

// keyed `<owner>/<name>@<sha>`
export const composeFiles = new Map<string, string>();
export const issueComments: StoredComment[] = [];

// a changed file as GitHub's pull request files API lists it, which leaves `patch` out of a file
// whose diff is too large to show
export interface StoredPullRequestFile {
  readonly filename: string;
  readonly patch?: string;
}

// keyed `<owner>/<name>#<number>`; a pull request with no entry changes no file
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
