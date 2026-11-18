import { expect, test } from 'bun:test';
import { buildMockBumpPullRequest } from './build-mock-bump-pull-request.ts';

test('it builds a default bump pull request', () => {
  expect(buildMockBumpPullRequest()).toStrictEqual({
    number: expect.toBeWithin(1, 10_000),
    authorLogin: expect.toBeString(),
    isCrossRepository: false,
    head: expect.toSatisfy((head: string) => /^[0-9a-f]{40}$/u.test(head)),
    labels: [],
    files: [],
    commits: [],
    checkRuns: [],
  });
});

test('it applies overrides on top of the defaults', () => {
  expect(
    buildMockBumpPullRequest({ number: 12, labels: ['auto-merge'], isCrossRepository: true }),
  ).toStrictEqual({
    number: 12,
    authorLogin: expect.toBeString(),
    isCrossRepository: true,
    head: expect.toSatisfy((head: string) => /^[0-9a-f]{40}$/u.test(head)),
    labels: ['auto-merge'],
    files: [],
    commits: [],
    checkRuns: [],
  });
});
