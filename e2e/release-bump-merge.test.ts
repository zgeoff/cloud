import { expect, test } from 'bun:test';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { isWorkflowTriggered } from '../scripts/test-utils/is-workflow-triggered.ts';

// a run started by a check on any branch but a release check branch would bill for nothing
async function setupTest() {
  const workflowText = await readFile(
    join(import.meta.dir, '..', '.github', 'workflows', 'release-bump-merge.yml'),
    'utf8',
  );

  return { workflowText };
}

test('it starts a run when a CI run on a release check branch completes', async () => {
  const ctx = await setupTest();

  expect(
    isWorkflowTriggered(ctx.workflowText, {
      name: 'workflow_run',
      workflow: 'CI',
      type: 'completed',
      headBranch: 'release-check/imp',
    }),
  ).toBeTrue();
});

test('it starts no run when a CI run on another branch completes', async () => {
  const ctx = await setupTest();

  expect(
    isWorkflowTriggered(ctx.workflowText, {
      name: 'workflow_run',
      workflow: 'CI',
      type: 'completed',
      headBranch: 'renovate/example',
    }),
  ).toBeFalse();
});

test('it starts no run when a NixOS checks run completes', async () => {
  const ctx = await setupTest();

  expect(
    isWorkflowTriggered(ctx.workflowText, {
      name: 'workflow_run',
      workflow: 'NixOS checks',
      type: 'completed',
      headBranch: 'release-check/imp',
    }),
  ).toBeFalse();
});
