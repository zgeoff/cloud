import { faker } from '@faker-js/faker';
import type { StubGitHubContext } from './build-stub-actions-scheduler.ts';

export interface MockWorkflowRun {
  readonly event: string;
  readonly conclusion: string;
  readonly head_sha: string;
  readonly head_repository: { readonly full_name: string };
}

export function buildMockWorkflowRunContext(
  overrides: Partial<MockWorkflowRun> = {},
): StubGitHubContext {
  const workflowRun: MockWorkflowRun = {
    event: 'push',
    conclusion: 'success',
    head_sha: faker.git.commitSha(),
    head_repository: { full_name: 'zgeoff/cloud' },
    ...overrides,
  };

  return {
    event_name: 'workflow_run',
    repository: 'zgeoff/cloud',
    event: { workflow_run: workflowRun },
  };
}
