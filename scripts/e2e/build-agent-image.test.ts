import { expect, onTestFinished, test } from 'bun:test';
import { mkdir, mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { resolveProgram } from '@zgeoff/rig/e2e';
import { run, start } from '@zgeoff/testing/process';
import { runProcess } from '../run-process.ts';
import { createSeededGitOrigin } from '../src/test-utils/create-seeded-git-origin.ts';
import { createStubAgentImageCheck } from '../src/test-utils/create-stub-agent-image-check.ts';
import { createStubImpCLI } from '../src/test-utils/create-stub-imp-cli.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'build-agent-image-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  const repo = await createSeededGitOrigin(directory);

  const temporary = join(directory, 'tmp');
  const fifo = join(directory, 'check-started');

  await mkdir(temporary);

  // a failed mkfifo leaves no fifo, so the read of it fails the test
  await runProcess(['mkfifo', fifo]);

  const program = await resolveProgram('build-agent-image');

  // start and run add to this process's environment; the build gets only repo.env, TMPDIR and the
  // case's own variables, so a GIT_DIR from a git hook cannot reach it
  const readBuildEnv = (env: Readonly<Record<string, string>>) => ({
    ...Object.fromEntries(Object.keys(process.env).map((name) => [name, undefined])),
    ...repo.env,
    TMPDIR: temporary,
    ...env,
  });

  return {
    directory,
    repo,
    temporary,
    fifo,
    clone: join(directory, 'clone'),
    startBuild: async (args: readonly string[], env: Readonly<Record<string, string>>) => {
      const child = await start(program.command, {
        args,
        cwd: join(directory, 'clone'),
        env: readBuildEnv(env),
      });

      onTestFinished(() => child.stop('SIGKILL'));

      return child;
    },
    runBuild: (args: readonly string[], env: Readonly<Record<string, string>>) =>
      run(program.command, {
        args,
        cwd: join(directory, 'clone'),
        env: readBuildEnv(env),
        timeoutMs: 10_000,
      }),
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

    // the build archives the pin; on an imp, bun under an empty pin runs the default with no note
    await writeFile(join(ctx.repo.seed, '.bun-version'), '');
    await createStubAgentImageCheck(ctx.repo.seed);

    await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
    await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the image']);
    await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'main']);
    await ctx.repo.git(['clone', '-q', ctx.repo.origin, ctx.clone]);

    const sha = await ctx.repo.git(['-C', ctx.repo.seed, 'rev-parse', 'HEAD']);
    const short = await ctx.repo.git(['-C', ctx.repo.seed, 'rev-parse', '--short', 'HEAD']);
    const imp = await createStubImpCLI(join(ctx.directory, 'imp'), { images: [] });

    const child = await ctx.startBuild([], {
      PATH: `${imp.bin}:${ctx.repo.env['PATH'] ?? ''}`,
      CHECK_STARTED: ctx.fifo,
    });

    await readFile(ctx.fifo);

    const exitCode = await child.stop(signal);

    // the program's stdout stays empty, so its whole output is its stderr
    expect({ exitCode, output: child.output() }).toStrictEqual({
      exitCode: code,
      output:
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
      [
        'new',
        `agent-check-${short}`,
        '--image',
        `agent-${short}`,
        '--memory',
        '1024',
        '--max-memory',
        '2048',
      ],
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

  // the build archives the pin; on an imp, bun under an empty pin runs the default with no note
  await writeFile(join(ctx.repo.seed, '.bun-version'), '');
  await createStubAgentImageCheck(ctx.repo.seed);

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the image']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'main']);
  await ctx.repo.git(['clone', '-q', ctx.repo.origin, ctx.clone]);

  const short = await ctx.repo.git(['-C', ctx.repo.seed, 'rev-parse', '--short', 'HEAD']);
  const imp = await createStubImpCLI(join(ctx.directory, 'imp'), { images: [] });

  const child = await ctx.startBuild(['--keep'], {
    PATH: `${imp.bin}:${ctx.repo.env['PATH'] ?? ''}`,
    CHECK_STARTED: ctx.fifo,
  });

  await readFile(ctx.fifo);

  const exitCode = await child.stop('SIGINT');
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

  // the build archives the pin; on an imp, bun under an empty pin runs the default with no note
  await writeFile(join(ctx.repo.seed, '.bun-version'), '');
  await createStubAgentImageCheck(ctx.repo.seed);

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the image']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'main']);
  await ctx.repo.git(['clone', '-q', ctx.repo.origin, ctx.clone]);

  const short = await ctx.repo.git(['-C', ctx.repo.seed, 'rev-parse', '--short', 'HEAD']);
  const imp = await createStubImpCLI(join(ctx.directory, 'imp'), { images: [] });

  const path = `${imp.bin}:${ctx.repo.env['PATH'] ?? ''}`;

  const interrupted = await ctx.startBuild([], { PATH: path, CHECK_STARTED: ctx.fifo });

  await readFile(ctx.fifo);

  await interrupted.stop('SIGTERM');

  const retry = await ctx.runBuild([], { PATH: path });

  expect({ exitCode: retry.exitCode, stdout: retry.stdout }).toStrictEqual({
    exitCode: 0,
    stdout: `agent-${short} imp-build-stub-agent-${short} check passed\n`,
  });
});
