import { expect, onTestFinished, test } from 'bun:test';
import { mkdir, mkdtemp, readFile, readdir, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { runProcess } from '../run-process.ts';

// The script runs as the host gets it: real bash reads it on stdin, then the bearer's line
async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'write-atc-gateway-token-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  const script = await readFile(new URL('write-atc-gateway-token.sh', import.meta.url));

  return {
    directory,
    script,
    env: { PATH: process.env['PATH'] ?? '/usr/bin:/bin', HOME: directory },
  };
}

test('it saves the line after the script as a root-only gateway-token in one rename', async () => {
  const ctx = await setupTest();

  const result = await runProcess(['bash', '-s', '--', ctx.directory], {
    stdin: Buffer.concat([ctx.script, Buffer.from('fixture-bearer\n')]),
    env: ctx.env,
  });

  expect(result.exitCode).toBe(0);
  expect(result.stderr.toString()).toBe('');

  const files = await readdir(ctx.directory);
  const token = await readFile(join(ctx.directory, 'gateway-token'), 'utf8');
  const status = await stat(join(ctx.directory, 'gateway-token'));

  expect(files).toStrictEqual(['gateway-token']);
  expect(token).toBe('fixture-bearer\n');
  expect((status.mode & 0o777).toString(8)).toBe('400');
});

test('it moves nothing into a directory that stands where gateway-token goes, and leaves no temporary file', async () => {
  const ctx = await setupTest();

  await mkdir(join(ctx.directory, 'gateway-token'));

  const result = await runProcess(['bash', '-s', '--', ctx.directory], {
    stdin: Buffer.concat([ctx.script, Buffer.from('fixture-bearer\n')]),
    env: ctx.env,
  });

  expect(result.exitCode).toBe(1);

  // what follows this text differs between coreutils versions
  expect(result.stderr.toString()).toStartWith(
    `mv: cannot overwrite directory '${ctx.directory}/gateway-token' with non-directory`,
  );

  const files = await readdir(ctx.directory);
  const inside = await readdir(join(ctx.directory, 'gateway-token'));

  expect(files).toStrictEqual(['gateway-token']);
  expect(inside).toStrictEqual([]);
});

test('it fails without a file when the secrets directory is missing', async () => {
  const ctx = await setupTest();

  const result = await runProcess(['bash', '-s', '--', join(ctx.directory, 'missing')], {
    stdin: Buffer.concat([ctx.script, Buffer.from('fixture-bearer\n')]),
    env: ctx.env,
  });

  expect(result.exitCode).toBe(1);

  expect(result.stderr.toString()).toBe(
    `mktemp: failed to create file via template '${ctx.directory}/missing/.gateway-token.XXXXXX': No such file or directory\n`,
  );

  const files = await readdir(ctx.directory);

  expect(files).toStrictEqual([]);
});
