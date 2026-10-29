import { expect, mock, test } from 'bun:test';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { checkWorkflowTriggers } from './check-workflow-triggers.ts';

function setupTest() {
  const printOut = mock<(text: string) => void>();
  const printErr = mock<(text: string) => void>();

  return { printOut, printErr };
}

test('it accepts workflows that start only on their own events', async () => {
  const ctx = setupTest();

  const files = new Map([
    [
      '/repo/.github/workflows/nixos-checks.yml',
      `on:
  pull_request:
    branches: [main]
  schedule:
    - cron: '0 3 * * *'
  workflow_dispatch:
jobs:
  nixos:
    if: github.event_name != 'pull_request' || github.event.pull_request.user.login != 'zgeoff-renovate[bot]'
`,
    ],
    [
      '/repo/.github/workflows/release-bump-merge.yml',
      `on:
  workflow_run:
    workflows: [CI]
    types: [completed]
    branches: ['release-check/**']
`,
    ],
    [
      '/repo/.github/workflows/audit-fix.yml',
      `on:
  workflow_run:
    workflows: [CI]
    types: [completed]
    branches: [main]
jobs:
  audit-fix:
    if: >-
      github.event_name != 'workflow_run' || (github.event.workflow_run.event == 'push' &&
      github.event.workflow_run.conclusion == 'failure' &&
      github.event.workflow_run.head_repository.full_name == github.repository)
`,
    ],
  ]);

  const exitCode = await checkWorkflowTriggers({
    args: ['/repo'],
    readText: (path) => Promise.resolve(files.get(path) ?? ''),
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(0);

  expect(ctx.printOut).toHaveBeenCalledExactlyOnceWith(
    'check-workflow-triggers: the NixOS checks, the release bump merge and the audit fix start only on their own events\n',
  );

  expect(ctx.printErr).not.toHaveBeenCalled();
});

test('it accepts the repository own workflows', async () => {
  const ctx = setupTest();

  const exitCode = await checkWorkflowTriggers({
    args: [join(import.meta.dir, '..')],
    readText: (path) => readFile(path, 'utf8'),
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(0);
  expect(ctx.printErr).not.toHaveBeenCalled();
});

test('it reports NixOS checks that neither a pull request, the schedule nor a dispatch starts', async () => {
  const ctx = setupTest();

  const files = new Map([
    ['/repo/.github/workflows/nixos-checks.yml', 'on:\n  push:\n    branches: [main]\n'],
    [
      '/repo/.github/workflows/release-bump-merge.yml',
      `on:
  workflow_run:
    workflows: [CI]
    types: [completed]
    branches: ['release-check/**']
`,
    ],
    [
      '/repo/.github/workflows/audit-fix.yml',
      `on:
  workflow_run:
    workflows: [CI]
    types: [completed]
    branches: [main]
jobs:
  audit-fix:
    if: >-
      github.event_name != 'workflow_run' || (github.event.workflow_run.event == 'push' &&
      github.event.workflow_run.conclusion == 'failure' &&
      github.event.workflow_run.head_repository.full_name == github.repository)
`,
    ],
  ]);

  const exitCode = await checkWorkflowTriggers({
    args: ['/repo'],
    readText: (path) => Promise.resolve(files.get(path) ?? ''),
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);

  expect(ctx.printErr).toHaveBeenCalledExactlyOnceWith(
    'nixos-checks.yml: a pull request that changes nixos/ starts no run\n' +
      'nixos-checks.yml: the nightly schedule starts no run\n' +
      'nixos-checks.yml: a dispatch starts no run\n' +
      'nixos-checks.yml: a Renovate pull request starts the nixos job\n',
  );

  expect(ctx.printOut).not.toHaveBeenCalled();
});

test('it reports NixOS checks whose job a Renovate pull request starts', async () => {
  const ctx = setupTest();

  const files = new Map([
    [
      '/repo/.github/workflows/nixos-checks.yml',
      `on:
  pull_request:
    branches: [main]
  schedule:
    - cron: '0 3 * * *'
  workflow_dispatch:
jobs:
  nixos:
    if: github.event_name != 'pull_request' || github.event.pull_request.user.login != 'zgeoff-release-check[bot]'
`,
    ],
    [
      '/repo/.github/workflows/release-bump-merge.yml',
      `on:
  workflow_run:
    workflows: [CI]
    types: [completed]
    branches: ['release-check/**']
`,
    ],
    [
      '/repo/.github/workflows/audit-fix.yml',
      `on:
  workflow_run:
    workflows: [CI]
    types: [completed]
    branches: [main]
jobs:
  audit-fix:
    if: >-
      github.event_name != 'workflow_run' || (github.event.workflow_run.event == 'push' &&
      github.event.workflow_run.conclusion == 'failure' &&
      github.event.workflow_run.head_repository.full_name == github.repository)
`,
    ],
  ]);

  const exitCode = await checkWorkflowTriggers({
    args: ['/repo'],
    readText: (path) => Promise.resolve(files.get(path) ?? ''),
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);

  expect(ctx.printErr).toHaveBeenCalledExactlyOnceWith(
    'nixos-checks.yml: a Renovate pull request starts the nixos job\n',
  );
});

test('it reports a release bump merge that a CI run on another branch starts', async () => {
  const ctx = setupTest();

  const files = new Map([
    [
      '/repo/.github/workflows/nixos-checks.yml',
      `on:
  pull_request:
    branches: [main]
  schedule:
    - cron: '0 3 * * *'
  workflow_dispatch:
jobs:
  nixos:
    if: github.event_name != 'pull_request' || github.event.pull_request.user.login != 'zgeoff-renovate[bot]'
`,
    ],
    [
      '/repo/.github/workflows/release-bump-merge.yml',
      'on:\n  workflow_run:\n    workflows: [CI]\n    types: [completed]\n',
    ],
    [
      '/repo/.github/workflows/audit-fix.yml',
      `on:
  workflow_run:
    workflows: [CI]
    types: [completed]
    branches: [main]
jobs:
  audit-fix:
    if: >-
      github.event_name != 'workflow_run' || (github.event.workflow_run.event == 'push' &&
      github.event.workflow_run.conclusion == 'failure' &&
      github.event.workflow_run.head_repository.full_name == github.repository)
`,
    ],
  ]);

  const exitCode = await checkWorkflowTriggers({
    args: ['/repo'],
    readText: (path) => Promise.resolve(files.get(path) ?? ''),
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);

  expect(ctx.printErr).toHaveBeenCalledExactlyOnceWith(
    'release-bump-merge.yml: a CI run that completes on another branch starts a run\n',
  );
});

test('it reports a release bump merge that a NixOS checks run starts and a CI run does not', async () => {
  const ctx = setupTest();

  const files = new Map([
    [
      '/repo/.github/workflows/nixos-checks.yml',
      `on:
  pull_request:
    branches: [main]
  schedule:
    - cron: '0 3 * * *'
  workflow_dispatch:
jobs:
  nixos:
    if: github.event_name != 'pull_request' || github.event.pull_request.user.login != 'zgeoff-renovate[bot]'
`,
    ],
    [
      '/repo/.github/workflows/release-bump-merge.yml',
      "on:\n  workflow_run:\n    workflows: ['NixOS checks']\n    types: [completed]\n",
    ],
    [
      '/repo/.github/workflows/audit-fix.yml',
      `on:
  workflow_run:
    workflows: [CI]
    types: [completed]
    branches: [main]
jobs:
  audit-fix:
    if: >-
      github.event_name != 'workflow_run' || (github.event.workflow_run.event == 'push' &&
      github.event.workflow_run.conclusion == 'failure' &&
      github.event.workflow_run.head_repository.full_name == github.repository)
`,
    ],
  ]);

  const exitCode = await checkWorkflowTriggers({
    args: ['/repo'],
    readText: (path) => Promise.resolve(files.get(path) ?? ''),
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);

  expect(ctx.printErr).toHaveBeenCalledExactlyOnceWith(
    'release-bump-merge.yml: a CI run that completes on a release check branch starts no run\n' +
      'release-bump-merge.yml: a NixOS checks run that completes starts a run\n',
  );
});

test('it reports an audit fix whose job the failed CI run of a fork pull request from main starts', async () => {
  const ctx = setupTest();

  const files = new Map([
    [
      '/repo/.github/workflows/nixos-checks.yml',
      `on:
  pull_request:
    branches: [main]
  schedule:
    - cron: '0 3 * * *'
  workflow_dispatch:
jobs:
  nixos:
    if: github.event_name != 'pull_request' || github.event.pull_request.user.login != 'zgeoff-renovate[bot]'
`,
    ],
    [
      '/repo/.github/workflows/release-bump-merge.yml',
      `on:
  workflow_run:
    workflows: [CI]
    types: [completed]
    branches: ['release-check/**']
`,
    ],
    [
      '/repo/.github/workflows/audit-fix.yml',
      `on:
  workflow_run:
    workflows: [CI]
    types: [completed]
    branches: [main]
jobs:
  audit-fix:
    if: github.event_name != 'workflow_run' || github.event.workflow_run.conclusion == 'failure'
`,
    ],
  ]);

  const exitCode = await checkWorkflowTriggers({
    args: ['/repo'],
    readText: (path) => Promise.resolve(files.get(path) ?? ''),
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);

  expect(ctx.printErr).toHaveBeenCalledExactlyOnceWith(
    'audit-fix.yml: a failed run that is not a push to this repository starts the audit-fix job\n',
  );

  expect(ctx.printOut).not.toHaveBeenCalled();
});

test('it reports an audit fix whose job a failed push run from another repository starts', async () => {
  const ctx = setupTest();

  const files = new Map([
    [
      '/repo/.github/workflows/nixos-checks.yml',
      `on:
  pull_request:
    branches: [main]
  schedule:
    - cron: '0 3 * * *'
  workflow_dispatch:
jobs:
  nixos:
    if: github.event_name != 'pull_request' || github.event.pull_request.user.login != 'zgeoff-renovate[bot]'
`,
    ],
    [
      '/repo/.github/workflows/release-bump-merge.yml',
      `on:
  workflow_run:
    workflows: [CI]
    types: [completed]
    branches: ['release-check/**']
`,
    ],
    [
      '/repo/.github/workflows/audit-fix.yml',
      `on:
  workflow_run:
    workflows: [CI]
    types: [completed]
    branches: [main]
jobs:
  audit-fix:
    if: >-
      github.event_name != 'workflow_run' || (github.event.workflow_run.event == 'push' &&
      github.event.workflow_run.conclusion == 'failure')
`,
    ],
  ]);

  const exitCode = await checkWorkflowTriggers({
    args: ['/repo'],
    readText: (path) => Promise.resolve(files.get(path) ?? ''),
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);

  expect(ctx.printErr).toHaveBeenCalledExactlyOnceWith(
    'audit-fix.yml: a failed run that is not a push to this repository starts the audit-fix job\n',
  );
});

test('it rejects more than one argument with its usage', async () => {
  const ctx = setupTest();
  const readText = mock<(path: string) => Promise<string>>();

  const exitCode = await checkWorkflowTriggers({
    args: ['/repo', 'extra'],
    readText,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(2);

  expect(ctx.printErr).toHaveBeenCalledExactlyOnceWith(
    'usage: check-workflow-triggers.ts [repo root]\n',
  );

  expect(readText).not.toHaveBeenCalled();
});

test('it rejects an option it does not know with its usage', async () => {
  const ctx = setupTest();
  const readText = mock<(path: string) => Promise<string>>();

  const exitCode = await checkWorkflowTriggers({
    args: ['--fix', '/repo'],
    readText,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(2);

  expect(ctx.printErr).toHaveBeenCalledExactlyOnceWith(
    'usage: check-workflow-triggers.ts [repo root]\n',
  );

  expect(readText).not.toHaveBeenCalled();
});
