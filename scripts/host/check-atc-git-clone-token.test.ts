import { expect, onTestFinished, test } from 'bun:test';
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { runProcess } from '../run-process.ts';

async function setupTest(httpCode: string) {
  const directory = await mkdtemp(join(tmpdir(), 'check-atc-git-clone-token-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  const bin = join(directory, 'bin');
  const secrets = join(directory, 'secrets');

  await mkdir(bin);
  await mkdir(secrets);

  // a curl that records its argv and the header file it is given, and answers the given code
  await writeFile(
    join(bin, 'curl'),
    `#!/usr/bin/env bash
printf '%s\\n' "$*" > "${bin}/curl-argv"
while [ "$#" -gt 0 ]; do
  case "$1" in -H) case "$2" in @*) cat "\${2#@}" > "${bin}/curl-header" ;; esac ;; esac
  shift
done
printf '%s' '${httpCode}'
`,
  );

  await chmod(join(bin, 'curl'), 0o755);

  const script = await readFile(new URL('check-atc-git-clone-token.sh', import.meta.url));

  return {
    bin,
    secrets,
    script,
    env: { PATH: `${bin}:${process.env['PATH'] ?? '/usr/bin:/bin'}`, HOME: directory },
  };
}

test('it exits 0 for a token that GitHub lets read the repo, with the token in a header file alone', async () => {
  const ctx = await setupTest('200');

  await writeFile(join(ctx.secrets, 'git-clone-token'), 'ghp_fixture_good\n');

  const result = await runProcess(['bash', '-s', '--', ctx.secrets, 'acme/widgets'], {
    stdin: ctx.script,
    env: ctx.env,
  });

  const argv = await readFile(join(ctx.bin, 'curl-argv'), 'utf8');
  const header = await readFile(join(ctx.bin, 'curl-header'), 'utf8');

  expect(result.exitCode).toBe(0);
  expect(argv).toContain('https://api.github.com/repos/acme/widgets');
  expect(argv).not.toContain('ghp_fixture_good');
  expect(header).toBe('Authorization: Bearer ghp_fixture_good\n');
});

test.each(['401', '403', '404'])('it exits 122 when GitHub answers %s', async (code) => {
  const ctx = await setupTest(code);

  await writeFile(join(ctx.secrets, 'git-clone-token'), 'ghp_fixture_old\n');

  const result = await runProcess(['bash', '-s', '--', ctx.secrets, 'acme/widgets'], {
    stdin: ctx.script,
    env: ctx.env,
  });

  expect(result.exitCode).toBe(122);
});

test('it exits 1 and names the answer when GitHub answers 500', async () => {
  const ctx = await setupTest('500');

  await writeFile(join(ctx.secrets, 'git-clone-token'), 'ghp_fixture\n');

  const result = await runProcess(['bash', '-s', '--', ctx.secrets, 'acme/widgets'], {
    stdin: ctx.script,
    env: ctx.env,
  });

  expect(result.exitCode).toBe(1);
  expect(result.stderr.toString()).toBe('GitHub answered 500\n');
});

test('it exits 120 when the file is absent', async () => {
  const ctx = await setupTest('200');

  const result = await runProcess(['bash', '-s', '--', ctx.secrets, 'acme/widgets'], {
    stdin: ctx.script,
    env: ctx.env,
  });

  expect(result.exitCode).toBe(120);
});

test.each(['', 'two\nlines\n', 'has space\n'])('it exits 121 for the file %j', async (content) => {
  const ctx = await setupTest('200');

  await writeFile(join(ctx.secrets, 'git-clone-token'), content);

  const result = await runProcess(['bash', '-s', '--', ctx.secrets, 'acme/widgets'], {
    stdin: ctx.script,
    env: ctx.env,
  });

  expect(result.exitCode).toBe(121);
});
