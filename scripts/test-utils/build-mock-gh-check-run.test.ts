import { expect, test } from 'bun:test';
import { buildMockGHCheckRun } from './build-mock-gh-check-run.ts';

test('it builds a default check run', () => {
  expect(buildMockGHCheckRun()).toStrictEqual({
    __typename: 'CheckRun',
    workflowName: expect.toBeString(),
    name: expect.toBeString(),
    status: 'COMPLETED',
    conclusion: 'SUCCESS',
  });
});

test('it applies overrides on top of the defaults', () => {
  expect(
    buildMockGHCheckRun({ workflowName: 'CI', name: 'ci', status: 'QUEUED', conclusion: null }),
  ).toStrictEqual({
    __typename: 'CheckRun',
    workflowName: 'CI',
    name: 'ci',
    status: 'QUEUED',
    conclusion: null,
  });
});
