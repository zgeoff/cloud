import { expect, mock, onTestFinished, test } from 'bun:test';
import { mkdtemp, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildStubRunner } from '../test-utils/build-stub-runner.ts';
import { renderNixieAPITypes } from './render-nixie-api-types.ts';
import { writeNixieAPIContract } from './write-nixie-api-contract.ts';

async function setupTest() {
  const dir = await mkdtemp(join(tmpdir(), 'write-nixie-api-contract-'));

  onTestFinished(() => rm(dir, { recursive: true, force: true }));

  return {
    dir,
    printOut: mock<(text: string) => void>(),
    printErr: mock<(text: string) => void>(),
  };
}

test('it writes the document that gh reads at the tag, and its types', async () => {
  const ctx = await setupTest();

  const document = '{"openapi":"3.1.1","info":{"title":"nixie","version":"0"},"paths":{}}\n';

  // the contents API answers the file base64-encoded in lines of 60, and gh's --jq prints the
  // string with its newlines
  const stub = buildStubRunner((call) =>
    call.argv.join(' ') ===
    'gh api repos/zgeoff/nixie/contents/libs/contract/openapi.json?ref=v0.31.0 --jq .content'
      ? {
          stdout:
            'eyJvcGVuYXBpIjoiMy4xLjEiLCJpbmZvIjp7InRpdGxlIjoibml4aWUiLCJ2\nZXJzaW9uIjoiMCJ9LCJwYXRocyI6e319Cg==\n',
        }
      : undefined,
  );

  const exitCode = await writeNixieAPIContract({
    args: ['v0.31.0'],
    dir: ctx.dir,
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  const written = await Bun.file(join(ctx.dir, 'openapi.json')).text();
  const types = await Bun.file(join(ctx.dir, 'openapi.d.ts')).text();
  const expectedTypes = await renderNixieAPITypes(document);

  expect(exitCode).toBe(0);
  expect(written).toBe(document);
  expect(types).toBe(expectedTypes);

  expect(ctx.printOut).toHaveBeenCalledExactlyOnceWith(
    "write-nixie-api-contract: wrote nixie v0.31.0's openapi.json and its types\n",
  );
});

test('it runs gh without its telemetry and update check', async () => {
  const ctx = await setupTest();

  const stub = buildStubRunner(() => ({
    stdout:
      'eyJvcGVuYXBpIjoiMy4xLjEiLCJpbmZvIjp7InRpdGxlIjoibml4aWUiLCJ2\nZXJzaW9uIjoiMCJ9LCJwYXRocyI6e319Cg==\n',
  }));

  await writeNixieAPIContract({
    args: ['v0.31.0'],
    dir: ctx.dir,
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(stub.calls[0]?.options.env).toMatchObject({
    GH_TELEMETRY: '0',
    DO_NOT_TRACK: '1',
    GH_NO_UPDATE_NOTIFIER: '1',
  });
});

test("it stops with gh's exit code and writes nothing when gh cannot read the tag", async () => {
  const ctx = await setupTest();

  const stub = buildStubRunner(() => ({
    exitCode: 1,
    stderr: 'gh: No commit found for the ref v0.99.0 (HTTP 404)\n',
  }));

  const exitCode = await writeNixieAPIContract({
    args: ['v0.99.0'],
    dir: ctx.dir,
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  const files = await readdir(ctx.dir);

  expect(exitCode).toBe(1);
  expect(files).toBeEmpty();

  expect(ctx.printErr).toHaveBeenCalledExactlyOnceWith(
    'gh: No commit found for the ref v0.99.0 (HTTP 404)\n',
  );
});

test.each([
  ['no tag', []],
  ['a tag that is not a release', ['main']],
  ['two tags', ['v0.31.0', 'v0.32.0']],
])('it prints its usage and exits 2 for %s', async (_label, args) => {
  const ctx = await setupTest();

  const exitCode = await writeNixieAPIContract({
    args,
    dir: ctx.dir,
    run: buildStubRunner().run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(2);

  expect(ctx.printErr).toHaveBeenCalledExactlyOnceWith(
    'usage: write-nixie-api-contract.ts <nixie release tag, such as v0.31.0>\n',
  );
});
