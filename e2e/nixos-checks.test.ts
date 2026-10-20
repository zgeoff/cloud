import { expect, test } from 'bun:test';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { isWorkflowTriggered } from '../scripts/test-utils/is-workflow-triggered.ts';

// The NixOS checks workflow's triggers through a stand-in for GitHub's trigger filters: the
// switch gate reads only the scheduled and dispatched runs on main, so no pull request starts one.
async function setupTest() {
  const workflowText = await readFile(
    join(import.meta.dir, '..', '.github', 'workflows', 'nixos-checks.yml'),
    'utf8',
  );

  return { workflowText };
}

test('it starts no run for a pull request that changes nixos/', async () => {
  const ctx = await setupTest();

  expect(
    isWorkflowTriggered(ctx.workflowText, {
      name: 'pull_request',
      baseBranch: 'main',
      files: ['nixos/flake.nix', 'nixos/flake.lock', 'packages/topology/index.ts'],
    }),
  ).toBeFalse();
});

test('it starts a run for the nightly schedule', async () => {
  const ctx = await setupTest();

  expect(isWorkflowTriggered(ctx.workflowText, { name: 'schedule' })).toBeTrue();
});

test('it starts a run for a dispatch', async () => {
  const ctx = await setupTest();

  expect(isWorkflowTriggered(ctx.workflowText, { name: 'workflow_dispatch' })).toBeTrue();
});
