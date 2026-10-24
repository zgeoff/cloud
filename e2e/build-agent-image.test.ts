import { expect, onTestFinished, test } from 'bun:test';
import { mkdir, mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { runProcess } from '../scripts/run-process.ts';
import { createGitOrigin } from '../scripts/test-utils/create-git-origin.ts';
import { createStubAgentImageCheck } from '../scripts/test-utils/create-stub-agent-image-check.ts';
import { createStubImpCLI } from '../scripts/test-utils/create-stub-imp-cli.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'build-agent-image-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  const repo = await createGitOrigin(directory);

  const temporary = join(directory, 'tmp');
  const fifo = join(directory, 'check-started');

  await mkdir(temporary);

  // a failed mkfifo leaves no fifo, so the read of it fails the test
  await runProcess(['mkfifo', fifo]);

  return {
    directory,
    repo,
    temporary,
    fifo,
    clone: join(directory, 'clone'),
    startBuild: (args: readonly string[], env: Readonly<Record<string, string>>) => {
      const child = Bun.spawn(
        ['bun', join(import.meta.dir, '..', 'scripts', 'build-agent-image.ts'), ...args],
        {
          cwd: join(directory, 'clone'),
          env: { ...repo.env, TMPDIR: temporary, ...env },
          stdin: 'ignore',
          stdout: 'pipe',
          stderr: 'pipe',
        },
      );

      onTestFinished(() => {
        child.kill('SIGKILL');
      });

      return child;
    },
  };
}

test.each([
  ['SIGINT', 130],
  ['SIGTERM', 143],
] as const)(
  'it removes the check imp, the image and the work tree on %s during the check, and exits %d',
  async (signal, code) => {
    const ctx = await setupTest();

    await mkdir(join(ctx.repo.seed, 'images/agent'), { recursive: true });
    await writeFile(join(ctx.repo.seed, 'images/agent/Dockerfile'), 'FROM scratch\n');
    await createStubAgentImageCheck(ctx.repo.seed);

    await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
    await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the image']);
    await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'main']);
    await ctx.repo.git(['clone', '-q', ctx.repo.origin, ctx.clone]);

    const sha = await ctx.repo.git(['-C', ctx.repo.seed, 'rev-parse', 'HEAD']);
    const short = await ctx.repo.git(['-C', ctx.repo.seed, 'rev-parse', '--short', 'HEAD']);
    const imp = await createStubImpCLI(join(ctx.directory, 'imp'), { images: [] });

    const child = ctx.startBuild([], {
      PATH: `${imp.bin}:${ctx.repo.env['PATH'] ?? ''}`,
      CHECK_STARTED: ctx.fifo,
    });

    await readFile(ctx.fifo);

    child.kill(signal);

    const [exitCode, stdout, stderr] = await Promise.all([
      child.exited,
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
    ]);

    expect({ exitCode, stdout, stderr }).toStrictEqual({
      exitCode: code,
      stdout: '',
      stderr:
        `building agent-${short} from ${sha}; impz image build shows no progress off a terminal\n` +
        `checking agent-${short} on a fresh imp, agent-check-${short}\n` +
        `agent-check-${short}\n` +
        `stopped by ${signal}; cleaning up\n`,
    });

    const calls = await imp.readCalls();
    const state = await imp.readState();
    const left = await readdir(ctx.temporary);

    expect(calls).toStrictEqual([
      ['image', 'ls', '--json'],
      ['ls', '--json'],
      [
        'image',
        'build',
        expect.toSatisfy((path: string) =>
          new RegExp(`^${ctx.temporary}/agent-image-build-[^/]+/src/images/agent$`, 'u').test(path),
        ),
        '--name',
        `agent-${short}`,
      ],
      ['image', 'ls', '--json'],
      ['new', `agent-check-${short}`, '--image', `agent-${short}`],
      ['rm', `agent-check-${short}`],
      ['image', 'rm', `agent-${short}`],
    ]);

    expect(state).toStrictEqual({ images: [], imps: [] });
    expect(left).toStrictEqual([]);
  },
);

test('it keeps the image on an interrupt with --keep, and still removes the check imp', async () => {
  const ctx = await setupTest();

  await mkdir(join(ctx.repo.seed, 'images/agent'), { recursive: true });
  await writeFile(join(ctx.repo.seed, 'images/agent/Dockerfile'), 'FROM scratch\n');
  await createStubAgentImageCheck(ctx.repo.seed);

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the image']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'main']);
  await ctx.repo.git(['clone', '-q', ctx.repo.origin, ctx.clone]);

  const short = await ctx.repo.git(['-C', ctx.repo.seed, 'rev-parse', '--short', 'HEAD']);
  const imp = await createStubImpCLI(join(ctx.directory, 'imp'), { images: [] });

  const child = ctx.startBuild(['--keep'], {
    PATH: `${imp.bin}:${ctx.repo.env['PATH'] ?? ''}`,
    CHECK_STARTED: ctx.fifo,
  });

  await readFile(ctx.fifo);

  child.kill('SIGINT');

  const exitCode = await child.exited;
  const state = await imp.readState();
  const left = await readdir(ctx.temporary);

  expect(exitCode).toBe(130);

  expect(state).toStrictEqual({
    images: [{ name: `agent-${short}`, digest: `imp-build-stub-agent-${short}` }],
    imps: [],
  });

  expect(left).toStrictEqual([]);
});

test('it lets a retry after an interrupt build and check the same commit', async () => {
  const ctx = await setupTest();

  await mkdir(join(ctx.repo.seed, 'images/agent'), { recursive: true });
  await writeFile(join(ctx.repo.seed, 'images/agent/Dockerfile'), 'FROM scratch\n');
  await createStubAgentImageCheck(ctx.repo.seed);

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the image']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'main']);
  await ctx.repo.git(['clone', '-q', ctx.repo.origin, ctx.clone]);

  const short = await ctx.repo.git(['-C', ctx.repo.seed, 'rev-parse', '--short', 'HEAD']);
  const imp = await createStubImpCLI(join(ctx.directory, 'imp'), { images: [] });

  const path = `${imp.bin}:${ctx.repo.env['PATH'] ?? ''}`;
  const interrupted = ctx.startBuild([], { PATH: path, CHECK_STARTED: ctx.fifo });

  await readFile(ctx.fifo);

  interrupted.kill('SIGTERM');

  await interrupted.exited;

  const retry = ctx.startBuild([], { PATH: path });

  const [exitCode, stdout] = await Promise.all([retry.exited, new Response(retry.stdout).text()]);

  expect({ exitCode, stdout }).toStrictEqual({
    exitCode: 0,
    stdout: `agent-${short} imp-build-stub-agent-${short} check passed\n`,
  });
});
