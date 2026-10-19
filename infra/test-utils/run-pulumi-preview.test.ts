import { expect, onTestFinished, test } from 'bun:test';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { runPulumiPreview } from './run-pulumi-preview.ts';

async function setupTest() {
  const stack = new AsyncDisposableStack();

  onTestFinished(() => stack.disposeAsync());

  const directory = await mkdtemp(join(tmpdir(), 'run-pulumi-preview-'));

  stack.defer(() => rm(directory, { recursive: true, force: true }));

  return { directory, stack };
}

test("it returns the preview's exit code and its stdout followed by its stderr, run in the project directory with the given environment", async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.directory, 'pulumi'),
    [
      '#!/bin/sh',
      `printf 'argv: %s\\n' "$*"`,
      `printf 'cwd: %s\\n' "$PWD"`,
      `printf 'case: %s\\n' "$CASE_DIR"`,
      'echo refused >&2',
      'exit 3',
      '',
    ].join('\n'),
    { mode: 0o755 },
  );

  const result = await runPulumiPreview({
    pulumiPath: join(ctx.directory, 'pulumi'),
    cwd: ctx.directory,
    env: { CASE_DIR: '/case' },
    cleanup: ctx.stack,
  });

  expect(result).toStrictEqual({
    exitCode: 3,
    output: `argv: preview --non-interactive\ncwd: ${ctx.directory}\ncase: /case\nrefused\n`,
  });
});
