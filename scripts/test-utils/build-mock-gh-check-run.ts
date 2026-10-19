import { faker } from '@faker-js/faker';

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
