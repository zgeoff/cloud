import { expect, test } from 'bun:test';
import { findEventBranch } from './find-event-branch.ts';

test('it finds the head branch of a check workflow that finished on a pull request', () => {
  expect(
    findEventBranch({
      name: 'workflow_run',
      repository: 'zgeoff/cloud',
      payload: {
        action: 'completed',
        workflow_run: {
          event: 'pull_request',
          head_branch: 'release-check/nixie',
          head_repository: { full_name: 'zgeoff/cloud' },
        },
      },
    }),
  ).toBe('release-check/nixie');
});

test('it finds the head branch of a pull request labelled auto-merge', () => {
  expect(
    findEventBranch({
      name: 'pull_request_target',
      repository: 'zgeoff/cloud',
      payload: {
        action: 'labeled',
        label: { name: 'auto-merge' },
        pull_request: {
          number: 31,
          head: { ref: 'release-check/atc', repo: { full_name: 'zgeoff/cloud' } },
        },
      },
    }),
  ).toBe('release-check/atc');
});

test('it finds no branch for a label other than auto-merge', () => {
  expect(
    findEventBranch({
      name: 'pull_request_target',
      repository: 'zgeoff/cloud',
      payload: {
        action: 'labeled',
        label: { name: 'needs-review' },
        pull_request: {
          head: { ref: 'release-check/atc', repo: { full_name: 'zgeoff/cloud' } },
        },
      },
    }),
  ).toBeUndefined();
});

test('it finds no branch for an unlabeled event', () => {
  expect(
    findEventBranch({
      name: 'pull_request_target',
      repository: 'zgeoff/cloud',
      payload: {
        action: 'unlabeled',
        label: { name: 'auto-merge' },
        pull_request: {
          head: { ref: 'release-check/atc', repo: { full_name: 'zgeoff/cloud' } },
        },
      },
    }),
  ).toBeUndefined();
});

test('it finds no branch for a label on a pull request from another repository', () => {
  expect(
    findEventBranch({
      name: 'pull_request_target',
      repository: 'zgeoff/cloud',
      payload: {
        action: 'labeled',
        label: { name: 'auto-merge' },
        pull_request: {
          head: { ref: 'release-check/atc', repo: { full_name: 'someone/cloud' } },
        },
      },
    }),
  ).toBeUndefined();
});

test('it finds no branch for a check workflow from another repository', () => {
  expect(
    findEventBranch({
      name: 'workflow_run',
      repository: 'zgeoff/cloud',
      payload: {
        workflow_run: {
          event: 'pull_request',
          head_branch: 'release-check/atc',
          head_repository: { full_name: 'someone/cloud' },
        },
      },
    }),
  ).toBeUndefined();
});

test('it finds no branch for a check workflow on a push', () => {
  expect(
    findEventBranch({
      name: 'workflow_run',
      repository: 'zgeoff/cloud',
      payload: {
        workflow_run: {
          event: 'push',
          head_branch: 'release-check/atc',
          head_repository: { full_name: 'zgeoff/cloud' },
        },
      },
    }),
  ).toBeUndefined();
});

test('it finds no branch for another event', () => {
  expect(
    findEventBranch({
      name: 'push',
      repository: 'zgeoff/cloud',
      payload: { ref: 'refs/heads/release-check/atc' },
    }),
  ).toBeUndefined();
});

test('it finds no branch in a payload without the fields', () => {
  expect(
    findEventBranch({ name: 'workflow_run', repository: 'zgeoff/cloud', payload: [] }),
  ).toBeUndefined();
});
