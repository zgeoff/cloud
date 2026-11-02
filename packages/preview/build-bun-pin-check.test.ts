import { expect, onTestFinished, test } from 'bun:test';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { $ } from 'bun';
import { buildBunPinCheck } from './build-bun-pin-check.ts';
import { buildContractStatus } from './build-contract-status.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'preview-bun-pin-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  return { directory };
}

test("it passes a repository that pins the run's release in both files", async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.directory, '.bun-version'), '7.3.1\n');

  await writeFile(
    join(ctx.directory, 'package.json'),
    '{\n  "name": "greenhouse",\n  "packageManager": "bun@7.3.1"\n}\n',
  );

  const result = await $`sh -c ${buildBunPinCheck('7.3.1')}`.cwd(ctx.directory).nothrow().quiet();

  expect({
    exitCode: result.exitCode,
    stdout: result.stdout.toString(),
    stderr: result.stderr.toString(),
  }).toStrictEqual({ exitCode: 0, stdout: '', stderr: '' });
});

test('it stops a repository whose .bun-version names another release', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.directory, '.bun-version'), '7.3.2\n');

  await writeFile(
    join(ctx.directory, 'package.json'),
    '{\n  "name": "greenhouse",\n  "packageManager": "bun@7.3.1"\n}\n',
  );

  const result = await $`sh -c ${buildBunPinCheck('7.3.1')}`.cwd(ctx.directory).nothrow().quiet();

  expect({
    exitCode: result.exitCode,
    stdout: result.stdout.toString(),
    stderr: result.stderr.toString(),
  }).toStrictEqual({
    exitCode: 1,
    stdout: '',
    stderr: 'the repository pins Bun 7.3.2, but the run installs Bun 7.3.1\n',
  });
});

test('it stops a repository whose packageManager names another release', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.directory, 'package.json'),
    '{\n  "name": "greenhouse",\n  "packageManager": "bun@7.4.0"\n}\n',
  );

  const result = await $`sh -c ${buildBunPinCheck('7.3.1')}`.cwd(ctx.directory).nothrow().quiet();

  expect({
    exitCode: result.exitCode,
    stdout: result.stdout.toString(),
    stderr: result.stderr.toString(),
  }).toStrictEqual({
    exitCode: 1,
    stdout: '',
    stderr: 'the repository pins Bun 7.4.0, but the run installs Bun 7.3.1\n',
  });
});

test('it reads a .bun-version with a v prefix and a CRLF ending as its bare release', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.directory, '.bun-version'), 'v7.3.1\r\n');

  const result = await $`sh -c ${buildBunPinCheck('7.3.1')}`.cwd(ctx.directory).nothrow().quiet();

  expect({
    exitCode: result.exitCode,
    stdout: result.stdout.toString(),
    stderr: result.stderr.toString(),
  }).toStrictEqual({ exitCode: 0, stdout: '', stderr: '' });
});

test('it passes a repository that pins no release', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.directory, 'package.json'), '{\n  "name": "greenhouse"\n}\n');

  const result = await $`sh -c ${buildBunPinCheck('7.3.1')}`.cwd(ctx.directory).nothrow().quiet();

  expect({
    exitCode: result.exitCode,
    stdout: result.stdout.toString(),
    stderr: result.stderr.toString(),
  }).toStrictEqual({ exitCode: 0, stdout: '', stderr: '' });
});

test('it gives the run a status that names both releases when they differ', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.directory, '.bun-version'), '7.3.2\n');

  const result = await $`sh -c ${buildBunPinCheck('7.3.1')}`.cwd(ctx.directory).nothrow().quiet();

  expect(
    buildContractStatus({ code: result.exitCode, output: result.stderr.toString() }, 600_000),
  ).toStrictEqual({
    state: 'failure',
    description: 'The repository pins Bun 7.3.2, but the run installs Bun 7.3.1',
  });
});
