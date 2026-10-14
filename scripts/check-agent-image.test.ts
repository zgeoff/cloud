// each test asserts every call, output and check-directory listing on its own, so its body is long
/* oxlint-disable max-statements */
import { expect, onTestFinished, test } from 'bun:test';
import { existsSync } from 'node:fs';
import { copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { checkAgentImage } from './check-agent-image.ts';
import { buildRealProgramHandler } from './test-utils/build-real-program-handler.ts';
import { buildStubAgentImageGuest } from './test-utils/build-stub-agent-image-guest.ts';
import { buildStubRunner } from './test-utils/build-stub-runner.ts';
import { startStubGitleaksRelease } from './test-utils/start-stub-gitleaks-release.ts';

// a checkout holding the real guest checks and gitleaks config, which every run sends or copies
async function setupTest() {
  const dir = await mkdtemp(join(tmpdir(), 'check-agent-image-'));

  onTestFinished(() => rm(dir, { recursive: true, force: true }));

  const repo = join(dir, 'repo');

  await mkdir(join(repo, 'scripts'), { recursive: true });
  await mkdir(join(repo, 'images/agent'), { recursive: true });

  await copyFile(
    join(import.meta.dir, 'agent-image-check-guest.sh'),
    join(repo, 'scripts/agent-image-check-guest.sh'),
  );

  await copyFile(
    join(import.meta.dir, 'agent-image-gitleaks.toml'),
    join(repo, 'scripts/agent-image-gitleaks.toml'),
  );

  const body = await readFile(join(import.meta.dir, 'agent-image-check-guest.sh'), 'utf8');

  const out: string[] = [];
  const err: string[] = [];

  return {
    repo,
    body,
    out,
    err,
    printOut: (text: string) => {
      out.push(text);
    },
    printErr: (text: string) => {
      err.push(text);
    },
  };
}

test('it runs the checks in a docker container with the check directory mounted, and returns their exit code', async () => {
  const ctx = await setupTest();
  const sum = await startStubGitleaksRelease('8.30.1', 'fake gitleaks\n');

  await writeFile(
    join(ctx.repo, 'images/agent/Dockerfile'),
    `FROM ubuntu:24.04\nARG GITLEAKS_VERSION=8.30.1\nARG GITLEAKS_SHA256=${sum}\nARG BUN_VERSION=1.4.2\n`,
  );

  const guest = buildStubAgentImageGuest({
    guest: { exitCode: 1, stdout: 'FAIL  bun              gave 1.4.1\n', stderr: 'warn\n' },
  });

  const stub = buildStubRunner(buildRealProgramHandler(['tar']), guest.handler);

  const exitCode = await checkAgentImage({
    args: ['--docker', 'cloud/agent-image'],
    repo: ctx.repo,
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  const [, run] = stub.calls;
  const mount = run?.argv[5] ?? '';

  expect(exitCode).toBe(1);

  expect(run?.argv).toStrictEqual([
    'docker',
    'run',
    '--rm',
    '-i',
    '-v',
    mount,
    'cloud/agent-image',
    'bash',
    '-s',
  ]);

  expect(mount).toStartWith(join(tmpdir(), 'agent-image-check-'));
  expect(mount).toEndWith('/agent-image-check:/run/agent-image-check:ro');

  expect(run?.stdin).toBe(
    `GITLEAKS_VERSION='8.30.1'\nBUN_VERSION='1.4.2'\ncheck_mode='docker'\n${ctx.body}`,
  );

  expect(run?.options.timeoutMs).toBe(900_000);
  expect(guest.seen).toStrictEqual([['gitleaks', 'gitleaks.toml']]);
  expect(ctx.out).toStrictEqual(['FAIL  bun              gave 1.4.1\n']);
  expect(ctx.err).toStrictEqual(['warn\n']);
});

test('it copies the check directory into the imp, then runs the checks there', async () => {
  const ctx = await setupTest();
  const sum = await startStubGitleaksRelease('8.30.1', 'fake gitleaks\n');

  await writeFile(
    join(ctx.repo, 'images/agent/Dockerfile'),
    `FROM ubuntu:24.04\nARG GITLEAKS_VERSION=8.30.1\nARG GITLEAKS_SHA256=${sum}\n`,
  );

  const guest = buildStubAgentImageGuest({ guest: { stdout: '== 0 failed\n' } });
  const stub = buildStubRunner(buildRealProgramHandler(['tar']), guest.handler);

  const exitCode = await checkAgentImage({
    args: ['--imp', 'agent-check'],
    repo: ctx.repo,
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  const dir = stub.calls[1]?.argv[2] ?? '';

  expect(exitCode).toBe(0);

  expect(stub.calls.slice(1).map((call) => call.argv)).toStrictEqual([
    ['imp', 'cp', dir, 'agent-check:/run/agent-image-check'],
    ['imp', 'exec', 'agent-check', '--', 'bash', '-s'],
  ]);

  expect(stub.calls[2]?.stdin).toBe(`GITLEAKS_VERSION='8.30.1'\ncheck_mode='imp'\n${ctx.body}`);
  expect(guest.seen).toStrictEqual([['gitleaks', 'gitleaks.toml']]);
  expect(ctx.out).toStrictEqual(['== 0 failed\n']);
});

test('it removes its work directory and stops when the copy into the imp fails', async () => {
  const ctx = await setupTest();
  const sum = await startStubGitleaksRelease('8.30.1', 'fake gitleaks\n');

  await writeFile(
    join(ctx.repo, 'images/agent/Dockerfile'),
    `ARG GITLEAKS_VERSION=8.30.1\nARG GITLEAKS_SHA256=${sum}\n`,
  );

  const guest = buildStubAgentImageGuest({
    guest: {},
    copy: { exitCode: 3, stderr: 'imp: no such imp\n' },
  });

  const stub = buildStubRunner(buildRealProgramHandler(['tar']), guest.handler);

  const exitCode = await checkAgentImage({
    args: ['--imp', 'gone'],
    repo: ctx.repo,
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  const work = dirname(stub.calls[1]?.argv[2] ?? '');

  expect(exitCode).toBe(3);
  expect(stub.calls).toHaveLength(2);
  expect(work).toStartWith(join(tmpdir(), 'agent-image-check-'));
  expect(existsSync(work)).toBe(false);
  expect(ctx.err).toStrictEqual(['imp: no such imp\n']);
});

test.each([
  ['no target', []],
  ['an unknown flag', ['--vm', 'agent']],
  ['an empty name', ['--imp', '']],
  ['an extra argument', ['--docker', 'cloud/agent-image', 'more']],
])('it prints its usage and exits 2 for %s', async (_label, args) => {
  const ctx = await setupTest();

  const stub = buildStubRunner();

  const exitCode = await checkAgentImage({
    args,
    repo: ctx.repo,
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(2);
  expect(ctx.err).toStrictEqual(['usage: check-agent-image.ts --imp <name> | --docker <image>\n']);
  expect(stub.calls).toStrictEqual([]);
});
