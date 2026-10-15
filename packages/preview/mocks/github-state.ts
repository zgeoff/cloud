// The in-memory GitHub that the MSW handlers serve: each repository's preview/compose.yaml by
// commit, and every issue comment. The preload clears both after each test.
export interface StoredComment {
  readonly id: number;
  readonly repo: string;
  readonly number: number;
  body: string;
}

// keyed `<owner>/<name>@<sha>`
export const composeFiles = new Map<string, string>();
export const issueComments: StoredComment[] = [];
