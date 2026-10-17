import { faker } from '@faker-js/faker';

// A GitHub Actions check run as `gh pr view --json statusCheckRollup` lists it, after the gh
// manual (gh_pr_view, 2026-10-17): by default an arbitrary job that completed with success
export interface MockGHCheckRun {
  readonly __typename: 'CheckRun';
  readonly workflowName: string;
  readonly name: string;
  readonly status: string;
  readonly conclusion: string | null;
}

export function buildMockGHCheckRun(overrides: Partial<MockGHCheckRun> = {}): MockGHCheckRun {
  return {
    __typename: 'CheckRun',
    workflowName: faker.word.words(2),
    name: faker.word.sample(),
    status: 'COMPLETED',
    conclusion: 'SUCCESS',
    ...overrides,
  };
}
