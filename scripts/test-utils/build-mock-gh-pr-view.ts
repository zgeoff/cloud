import { faker } from '@faker-js/faker';

// What `gh pr view --json` prints for the fields the merge reads, after the gh manual (gh_pr_view,
// 2026-10-17): by default an arbitrary author's pull request with no labels, files, commits or
// checks, so each test states the fields its case rests on.
export interface MockGHPRView {
  readonly author: { readonly login: string };
  readonly isCrossRepository: boolean;
  readonly headRefOid: string;
  readonly labels: readonly { readonly name: string }[];
  readonly files: readonly { readonly path: string }[];
  readonly commits: readonly {
    readonly oid: string;
    readonly authors: readonly { readonly login: string }[];
  }[];
  readonly statusCheckRollup: readonly object[];
}

export function buildMockGHPRView(overrides: Partial<MockGHPRView> = {}): MockGHPRView {
  return {
    author: { login: faker.internet.username() },
    isCrossRepository: false,
    headRefOid: faker.git.commitSha(),
    labels: [],
    files: [],
    commits: [],
    statusCheckRollup: [],
    ...overrides,
  };
}
