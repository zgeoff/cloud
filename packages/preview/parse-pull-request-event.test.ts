import { expect, test } from 'bun:test';
import type { PullRequestAction } from './parse-pull-request-event.ts';
import { parsePullRequestEvent } from './parse-pull-request-event.ts';

test.each<[string, PullRequestAction]>([
  ['opened', 'open'],
  ['reopened', 'open'],
  ['synchronize', 'update'],
  ['closed', 'close'],
])('it reads the %s action as %s', (action, expected) => {
  const event = parsePullRequestEvent({
    action,
    number: 17,
    repository: { full_name: 'acme/greenhouse' },
    pull_request: {
      head: {
        sha: '4d2a7c1e9b0f3a5d6c8e7f1a2b3c4d5e6f7a8b9c',
        repo: { full_name: 'acme/greenhouse' },
      },
    },
  });

  expect(event).toStrictEqual({
    action: expected,
    repo: 'acme/greenhouse',
    number: 17,
    headSHA: '4d2a7c1e9b0f3a5d6c8e7f1a2b3c4d5e6f7a8b9c',
    fromFork: false,
  });
});

test('it returns null for an action that changes no preview', () => {
  expect(
    parsePullRequestEvent({
      action: 'labeled',
      number: 17,
      repository: { full_name: 'acme/greenhouse' },
      pull_request: {
        head: {
          sha: '4d2a7c1e9b0f3a5d6c8e7f1a2b3c4d5e6f7a8b9c',
          repo: { full_name: 'acme/greenhouse' },
        },
      },
    }),
  ).toBeNull();
});

test('it marks a head branch in another repository as a fork', () => {
  const event = parsePullRequestEvent({
    action: 'opened',
    number: 17,
    repository: { full_name: 'acme/greenhouse' },
    pull_request: {
      head: {
        sha: '4d2a7c1e9b0f3a5d6c8e7f1a2b3c4d5e6f7a8b9c',
        repo: { full_name: 'stranger/greenhouse' },
      },
    },
  });

  expect(event?.fromFork).toBeTrue();
});

test('it marks a head branch whose fork was deleted as a fork', () => {
  const event = parsePullRequestEvent({
    action: 'closed',
    number: 17,
    repository: { full_name: 'acme/greenhouse' },
    pull_request: { head: { sha: '4d2a7c1e9b0f3a5d6c8e7f1a2b3c4d5e6f7a8b9c', repo: null } },
  });

  expect(event?.fromFork).toBeTrue();
});

test('it rejects a payload whose head commit is not a full SHA', () => {
  expect(() =>
    parsePullRequestEvent({
      action: 'opened',
      number: 17,
      repository: { full_name: 'acme/greenhouse' },
      pull_request: { head: { sha: '4d2a7c1', repo: { full_name: 'acme/greenhouse' } } },
    }),
  ).toThrowWithMessage(TypeError, 'the payload has no full head commit SHA');
});

test('it rejects a payload without a pull request number', () => {
  expect(() =>
    parsePullRequestEvent({
      action: 'opened',
      number: 0,
      repository: { full_name: 'acme/greenhouse' },
      pull_request: {
        head: {
          sha: '4d2a7c1e9b0f3a5d6c8e7f1a2b3c4d5e6f7a8b9c',
          repo: { full_name: 'acme/greenhouse' },
        },
      },
    }),
  ).toThrowWithMessage(TypeError, 'the payload has no pull request number');
});

test('it rejects a payload without a repository', () => {
  expect(() =>
    parsePullRequestEvent({
      action: 'opened',
      number: 17,
      pull_request: {
        head: {
          sha: '4d2a7c1e9b0f3a5d6c8e7f1a2b3c4d5e6f7a8b9c',
          repo: { full_name: 'acme/greenhouse' },
        },
      },
    }),
  ).toThrowWithMessage(TypeError, 'the payload has no repository object');
});
