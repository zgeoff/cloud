import { expect, mock, test } from 'bun:test';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { checkWorkflowTriggers } from './check-workflow-triggers.ts';

function setupTest() {
  const printOut = mock<(text: string) => void>();
  const printErr = mock<(text: string) => void>();

  const nixosChecks = `on:
  pull_request:
    branches: [main]
  schedule:
    - cron: '0 3 * * *'
  workflow_dispatch:
`;

  const releaseBumpMerge = `on:
  workflow_run:
    workflows: [CI]
    types: [completed]
    branches: ['release-check/**']
`;

  return { printOut, printErr, nixosChecks, releaseBumpMerge };
}

test('it accepts workflows that start only on their own events', async () => {
  const ctx = setupTest();

  const files = new Map([
    ['/repo/.github/workflows/nixos-checks.yml', ctx.nixosChecks],
    ['/repo/.github/workflows/release-bump-merge.yml', ctx.releaseBumpMerge],
  ]);

  const exitCode = await checkWorkflowTriggers({
    args: ['/repo'],
    readText: (path) => Promise.resolve(files.get(path) ?? ''),
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(0);

  expect(ctx.printOut).toHaveBeenCalledExactlyOnceWith(
    'check-workflow-triggers: the NixOS checks and the release bump merge start only on their own events\n',
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
    ['/repo/.github/workflows/release-bump-merge.yml', ctx.releaseBumpMerge],
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
      'nixos-checks.yml: a dispatch starts no run\n',
  );

  expect(ctx.printOut).not.toHaveBeenCalled();
});

test('it reports a release bump merge that a CI run on another branch starts', async () => {
  const ctx = setupTest();

  const files = new Map([
    ['/repo/.github/workflows/nixos-checks.yml', ctx.nixosChecks],
    [
      '/repo/.github/workflows/release-bump-merge.yml',
      'on:\n  workflow_run:\n    workflows: [CI]\n    types: [completed]\n',
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
    ['/repo/.github/workflows/nixos-checks.yml', ctx.nixosChecks],
    [
      '/repo/.github/workflows/release-bump-merge.yml',
      "on:\n  workflow_run:\n    workflows: ['NixOS checks']\n    types: [completed]\n",
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
