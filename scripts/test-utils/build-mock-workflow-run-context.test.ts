import { expect, test } from 'bun:test';
import { buildMockWorkflowRunContext } from './build-mock-workflow-run-context.ts';

test('it builds a default workflow run context', () => {
  expect(buildMockWorkflowRunContext()).toStrictEqual({
    event_name: 'workflow_run',
    repository: 'zgeoff/cloud',
    event: {
      workflow_run: {
        event: 'push',
        conclusion: 'success',
        head_sha: expect.toSatisfy((sha: string) => /^[0-9a-f]{40}$/u.test(sha)),
        head_repository: { full_name: 'zgeoff/cloud' },
      },
    },
  });
});

test('it applies overrides on top of the defaults', () => {
  expect(
    buildMockWorkflowRunContext({
      conclusion: 'failure',
      head_sha: '1111111111111111111111111111111111111111',
    }),
  ).toStrictEqual({
    event_name: 'workflow_run',
    repository: 'zgeoff/cloud',
    event: {
      workflow_run: {
        event: 'push',
        conclusion: 'failure',
        head_sha: '1111111111111111111111111111111111111111',
        head_repository: { full_name: 'zgeoff/cloud' },
      },
    },
  });
});
