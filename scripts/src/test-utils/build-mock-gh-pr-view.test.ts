import { expect, test } from 'bun:test';
import { buildMockGHPRView } from './build-mock-gh-pr-view.ts';

test('it builds a default pull request view', () => {
  expect(buildMockGHPRView()).toStrictEqual({
    author: { login: expect.toBeString() },
    isCrossRepository: false,
    headRefOid: expect.toSatisfy((head: string) => /^[0-9a-f]{40}$/u.test(head)),
    labels: [],
    files: [],
    commits: [],
    statusCheckRollup: [],
  });
});

test('it applies overrides on top of the defaults', () => {
  expect(
    buildMockGHPRView({
      headRefOid: '1111111111111111111111111111111111111111',
      labels: [{ name: 'auto-merge' }],
    }),
  ).toStrictEqual({
    author: { login: expect.toBeString() },
    isCrossRepository: false,
    headRefOid: '1111111111111111111111111111111111111111',
    labels: [{ name: 'auto-merge' }],
    files: [],
    commits: [],
    statusCheckRollup: [],
  });
});
