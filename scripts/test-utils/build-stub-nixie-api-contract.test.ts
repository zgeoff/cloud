import { expect, onTestFinished, test } from 'bun:test';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildStubNixieAPIContract } from './build-stub-nixie-api-contract.ts';
import { buildStubRunner } from './build-stub-runner.ts';

async function setupTest() {
  const root = await mkdtemp(join(tmpdir(), 'build-stub-nixie-api-contract-'));

  onTestFinished(() => rm(root, { recursive: true, force: true }));

  await mkdir(join(root, 'scripts/nixie-api'), { recursive: true });

  return { root };
}

test('it writes both contract files for the tag and prints the script’s line', async () => {
  const ctx = await setupTest();

  const stub = buildStubRunner(buildStubNixieAPIContract({}));

  const result = await stub.run(
    ['bun', join(ctx.root, 'scripts/nixie-api/write-nixie-api-contract.ts'), 'v0.33.0'],
    { cwd: ctx.root },
  );

  const document = await readFile(join(ctx.root, 'scripts/nixie-api/openapi.json'), 'utf8');
  const types = await readFile(join(ctx.root, 'scripts/nixie-api/openapi.d.ts'), 'utf8');

  expect(result.exitCode).toBe(0);

  expect(result.stdout.toString()).toBe(
    "write-nixie-api-contract: wrote nixie v0.33.0's openapi.json and its types\n",
  );

  expect(document).toBe('{"info":{"version":"v0.33.0"}}\n');
  expect(types).toBe('// nixie v0.33.0\n');
});

test('it fails with the scenario’s error and leaves the files as they were', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.root, 'scripts/nixie-api/openapi.json'), '{}\n');

  const stub = buildStubRunner(buildStubNixieAPIContract({ error: 'gh: Not Found (HTTP 404)' }));

  const result = await stub.run(
    ['bun', join(ctx.root, 'scripts/nixie-api/write-nixie-api-contract.ts'), 'v0.33.0'],
    { cwd: ctx.root },
  );

  const document = await readFile(join(ctx.root, 'scripts/nixie-api/openapi.json'), 'utf8');

  expect({ exitCode: result.exitCode, stderr: result.stderr.toString() }).toStrictEqual({
    exitCode: 1,
    stderr: 'gh: Not Found (HTTP 404)\n',
  });

  expect(document).toBe('{}\n');
});

test('it leaves a call from another directory unanswered', async () => {
  const ctx = await setupTest();

  const stub = buildStubRunner(buildStubNixieAPIContract({}));

  const result = await stub.run(
    ['bun', join(ctx.root, 'scripts/nixie-api/write-nixie-api-contract.ts'), 'v0.33.0'],
    { cwd: join(ctx.root, 'scripts') },
  );

  expect(result.exitCode).toBe(97);
});
