import { expect, mock, onTestFinished, test } from 'bun:test';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { checkWorkflowConcurrency } from './check-workflow-concurrency.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'check-workflow-concurrency-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  await mkdir(join(directory, '.github', 'workflows'), { recursive: true });

  const printOut = mock<(text: string) => void>();
  const printErr = mock<(text: string) => void>();

  return { directory, printOut, printErr };
}

test('it accepts CI runs that cancel within a branch and an apply group that never cancels', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.directory, '.github', 'workflows', 'ci.yml'),
    `concurrency:
  group: ci-\${{ github.event_name }}-\${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: true
`,
  );

  await writeFile(
    join(ctx.directory, '.github', 'workflows', 'deploy-prod.yml'),
    `jobs:
  apply:
    concurrency:
      group: deploy-prod
      cancel-in-progress: false
`,
  );

  const exitCode = await checkWorkflowConcurrency({
    args: [ctx.directory],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(0);

  expect(ctx.printOut).toHaveBeenCalledExactlyOnceWith(
    "check-workflow-concurrency: a push to main cancels main's earlier CI run, and never an apply\n",
  );

  expect(ctx.printErr).not.toHaveBeenCalled();
});

test('it accepts the repository own workflows', async () => {
  const ctx = await setupTest();

  const exitCode = await checkWorkflowConcurrency({
    args: [join(import.meta.dir, '..')],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(0);
  expect(ctx.printErr).not.toHaveBeenCalled();
});

test('it reports CI that cancels only pull request runs', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.directory, '.github', 'workflows', 'ci.yml'),
    `concurrency:
  group: ci-\${{ github.event_name }}-\${{ github.event.pull_request.number || github.sha }}
  cancel-in-progress: \${{ github.event_name == 'pull_request' }}
`,
  );

  await writeFile(
    join(ctx.directory, '.github', 'workflows', 'deploy-prod.yml'),
    `jobs:
  apply:
    concurrency:
      group: deploy-prod
      cancel-in-progress: false
`,
  );

  const exitCode = await checkWorkflowConcurrency({
    args: [ctx.directory],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);

  expect(ctx.printErr).toHaveBeenCalledExactlyOnceWith(
    'ci.yml: the concurrency group holds github.sha, so pushes to main never share it\n' +
      'ci.yml: cancel-in-progress is not true, so a push to main never cancels the earlier run\n',
  );

  expect(ctx.printOut).not.toHaveBeenCalled();
});

test('it reports CI with no concurrency group', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.directory, '.github', 'workflows', 'ci.yml'), 'name: CI\n');

  await writeFile(
    join(ctx.directory, '.github', 'workflows', 'deploy-prod.yml'),
    `jobs:
  apply:
    concurrency:
      group: deploy-prod
      cancel-in-progress: false
`,
  );

  const exitCode = await checkWorkflowConcurrency({
    args: [ctx.directory],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);

  expect(ctx.printErr).toHaveBeenCalledExactlyOnceWith(
    'ci.yml: the workflow has no concurrency group\n' +
      'ci.yml: cancel-in-progress is not true, so a push to main never cancels the earlier run\n',
  );
});

test('it reports an apply job whose group a new run can cancel', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.directory, '.github', 'workflows', 'ci.yml'),
    `concurrency:
  group: ci-\${{ github.event_name }}-\${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: true
`,
  );

  await writeFile(
    join(ctx.directory, '.github', 'workflows', 'deploy-prod.yml'),
    `jobs:
  apply:
    concurrency:
      group: deploy-\${{ github.ref }}
      cancel-in-progress: true
`,
  );

  const exitCode = await checkWorkflowConcurrency({
    args: [ctx.directory],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);

  expect(ctx.printErr).toHaveBeenCalledExactlyOnceWith(
    'deploy-prod.yml: the apply job has no fixed concurrency group of its own\n' +
      "deploy-prod.yml: the apply job's cancel-in-progress is not false, so a new run can cancel an apply\n",
  );
});

test('it rejects more than one argument with its usage', async () => {
  const ctx = await setupTest();

  const exitCode = await checkWorkflowConcurrency({
    args: [ctx.directory, 'extra'],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(2);

  expect(ctx.printErr).toHaveBeenCalledExactlyOnceWith(
    'usage: check-workflow-concurrency.ts [repo root]\n',
  );
});
