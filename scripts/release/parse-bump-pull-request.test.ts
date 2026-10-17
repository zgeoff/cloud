import { expect, test } from 'bun:test';
import { buildMockGHCheckRun } from '../test-utils/build-mock-gh-check-run.ts';
import { buildMockGHPRView } from '../test-utils/build-mock-gh-pr-view.ts';
import { parseBumpPullRequest } from './parse-bump-pull-request.ts';

test('it parses a view and leaves out commit statuses from other apps', () => {
  const view = buildMockGHPRView({
    author: { login: 'app/cloud-release-check' },
    isCrossRepository: false,
    headRefOid: '1111111111111111111111111111111111111111',
    labels: [{ name: 'update:minor' }, { name: 'auto-merge' }],
    files: [{ path: 'images/atc-gateway/versions.env' }, { path: 'images/agent/Dockerfile' }],
    commits: [{ oid: '1111111', authors: [{ login: 'cloud-release-check[bot]' }] }],
    statusCheckRollup: [
      buildMockGHCheckRun({ workflowName: 'CI', name: 'ci' }),
      buildMockGHCheckRun({
        workflowName: 'agent image',
        name: 'check',
        status: 'IN_PROGRESS',
        conclusion: null,
      }),
      { __typename: 'StatusContext', context: 'CodeRabbit', state: 'PENDING' },
    ],
  });

  expect(parseBumpPullRequest(7, JSON.stringify(view))).toStrictEqual({
    number: 7,
    authorLogin: 'app/cloud-release-check',
    isCrossRepository: false,
    head: '1111111111111111111111111111111111111111',
    labels: ['update:minor', 'auto-merge'],
    files: ['images/atc-gateway/versions.env', 'images/agent/Dockerfile'],
    commits: [{ oid: '1111111', authorLogins: ['cloud-release-check[bot]'] }],
    checkRuns: [
      { workflow: 'CI', name: 'ci', status: 'COMPLETED', conclusion: 'SUCCESS' },
      { workflow: 'agent image', name: 'check', status: 'IN_PROGRESS', conclusion: null },
    ],
  });
});

test('it rejects a view without its files', () => {
  const text = JSON.stringify({
    author: { login: 'app/cloud-release-check' },
    isCrossRepository: false,
    headRefOid: '1111111111111111111111111111111111111111',
    labels: [],
    commits: [],
    statusCheckRollup: [],
  });

  expect(parseBumpPullRequest(7, text)).toStrictEqual(
    new Error('gh pr view 7 printed no usable files'),
  );
});

test('it rejects a view whose check run lacks its workflow', () => {
  const text = JSON.stringify({
    author: { login: 'app/cloud-release-check' },
    isCrossRepository: false,
    headRefOid: '1111111111111111111111111111111111111111',
    labels: [],
    files: [],
    commits: [],
    statusCheckRollup: [
      { __typename: 'CheckRun', name: 'ci', status: 'COMPLETED', conclusion: 'SUCCESS' },
    ],
  });

  expect(parseBumpPullRequest(7, text)).toStrictEqual(
    new Error('gh pr view 7 printed no usable checkRuns'),
  );
});

test('it rejects a view without an author login', () => {
  const text = JSON.stringify({
    author: {},
    isCrossRepository: false,
    headRefOid: '1111111111111111111111111111111111111111',
    labels: [],
    files: [],
    commits: [],
    statusCheckRollup: [],
  });

  expect(parseBumpPullRequest(7, text)).toStrictEqual(
    new Error('gh pr view 7 printed no usable authorLogin'),
  );
});

test('it rejects output that is not JSON', () => {
  expect(parseBumpPullRequest(7, 'not json')).toStrictEqual(
    new Error('gh pr view 7 printed no usable authorLogin'),
  );
});
