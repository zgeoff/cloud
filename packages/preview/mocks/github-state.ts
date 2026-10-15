// The in-memory GitHub that the MSW handlers serve: each repository's preview/compose.yaml by
// commit, and every issue comment. The preload clears both after each test.
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
