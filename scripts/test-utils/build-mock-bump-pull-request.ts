import { faker } from '@faker-js/faker';
import type { BumpPullRequest } from '../release/decide.ts';

// A release bump pull request as decide reads it: by default one that nobody's rules accept,
// opened by an arbitrary author with no labels, files, commits or checks, so each test states the
// fields its decision rests on.
export function buildMockBumpPullRequest(
  overrides: Partial<BumpPullRequest> = {},
): BumpPullRequest {
  return {
    number: faker.number.int({ min: 1, max: 9999 }),
    authorLogin: faker.internet.username(),
    isCrossRepository: false,
    head: faker.git.commitSha(),
    labels: [],
    files: [],
    commits: [],
    checkRuns: [],
    ...overrides,
  };
}
