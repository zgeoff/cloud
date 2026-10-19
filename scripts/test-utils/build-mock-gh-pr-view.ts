import { faker } from '@faker-js/faker';

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
