import { expect, onTestFinished, test } from 'bun:test';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { runPulumiPreview } from './run-pulumi-preview.ts';

async function setupTest() {
  const stack = new AsyncDisposableStack();

  onTestFinished(() => stack.disposeAsync());

  const dir = await mkdtemp(join(tmpdir(), 'run-pulumi-preview-'));

  stack.defer(() => rm(dir, { recursive: true, force: true }));

  return { dir, stack };
}

test("it returns the preview's exit code and its stdout followed by its stderr, run in the project directory with the given environment", async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.dir, 'pulumi'),
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
    pulumiPath: join(ctx.dir, 'pulumi'),
    cwd: ctx.dir,
    env: { CASE_DIR: '/case' },
    cleanup: ctx.stack,
  });

  expect(result).toStrictEqual({
    exitCode: 3,
    output: `argv: preview --non-interactive\ncwd: ${ctx.dir}\ncase: /case\nrefused\n`,
  });
});
