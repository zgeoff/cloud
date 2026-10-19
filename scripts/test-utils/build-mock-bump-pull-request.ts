import { faker } from '@faker-js/faker';
import type { BumpPullRequest } from '../release/decide.ts';

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
