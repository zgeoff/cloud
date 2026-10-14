// each test commits its own image to a real origin and asserts every output on its own, so its
// body is long
/* oxlint-disable max-lines-per-function, max-statements */
import { expect, onTestFinished, test } from 'bun:test';
import { access, mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { createAgentImage } from './create-agent-image.ts';
import { buildRealProgramHandler } from './test-utils/build-real-program-handler.ts';
import { buildStubCheckAgentImage } from './test-utils/build-stub-check-agent-image.ts';
import { buildStubImp } from './test-utils/build-stub-imp.ts';
import { buildStubRunner } from './test-utils/build-stub-runner.ts';
import { createGitOrigin } from './test-utils/create-git-origin.ts';

// a real origin and seed for each case to commit its image to, and recorders for the output
async function setupTest() {
  const dir = await mkdtemp(join(tmpdir(), 'create-agent-image-'));

  onTestFinished(() => rm(dir, { recursive: true, force: true }));

  const repo = await createGitOrigin(dir);

  const out: string[] = [];
  const err: string[] = [];

  return {
    dir,
    repo,
    clone: join(dir, 'clone'),
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

test('it builds the head of main from its archive, checks it on a fresh imp, and removes the imp', async () => {
  const ctx = await setupTest();

  await mkdir(join(ctx.repo.seed, 'images/agent'), { recursive: true });
  await mkdir(join(ctx.repo.seed, 'scripts'));

  await writeFile(
    join(ctx.repo.seed, 'images/agent/Dockerfile'),
    'FROM ghcr.io/zgeoff/imp-base:0.33.0\n',
  );

  await writeFile(join(ctx.repo.seed, 'scripts/check-agent-image.ts'), '');

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the image']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'main']);
  await ctx.repo.git(['clone', '-q', ctx.repo.origin, ctx.clone]);

  await writeFile(join(ctx.clone, 'images/agent/Dockerfile'), 'FROM uncommitted\n');

  const sha = await ctx.repo.git(['-C', ctx.repo.seed, 'rev-parse', 'HEAD']);
  const short = await ctx.repo.git(['-C', ctx.repo.seed, 'rev-parse', '--short', 'HEAD']);

  const imp = buildStubImp({ images: [] });

  const stub = buildStubRunner(
    buildRealProgramHandler(['git', 'tar'], ctx.repo.env),
    imp.handler,
    buildStubCheckAgentImage(0),
  );

  const exitCode = await createAgentImage({
    args: [],
    cwd: ctx.clone,
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  const impCalls = stub.calls.filter((call) => call.argv[0] !== 'git' && call.argv[0] !== 'tar');
  const src = dirname(dirname(impCalls[2]?.argv[3] ?? ''));

  expect(exitCode).toBe(0);
  expect(ctx.out).toStrictEqual([`agent-${short} imp-build-stub-agent-${short} check passed\n`]);

  expect(ctx.err.join('')).toBe(
    `building agent-${short} from ${sha}; imp image build shows no progress off a terminal\n` +
      `checking agent-${short} on a fresh imp, agent-check-${short}\n` +
      `agent-check-${short}\n` +
      '== 0 failed\n',
  );

  expect(imp.builtDockerfiles).toStrictEqual(['FROM ghcr.io/zgeoff/imp-base:0.33.0\n']);

  expect(imp.images).toStrictEqual([
    { name: `agent-${short}`, digest: `imp-build-stub-agent-${short}` },
  ]);

  expect(imp.imps).toStrictEqual([]);

  expect(impCalls.map((call) => call.argv)).toStrictEqual([
    ['imp', 'image', 'ls', '--json'],
    ['imp', 'ls', '--json'],
    ['imp', 'image', 'build', join(src, 'images/agent'), '--name', `agent-${short}`],
    ['imp', 'image', 'ls', '--json'],
    ['imp', 'new', `agent-check-${short}`, '--image', `agent-${short}`],
    ['bun', join(src, 'scripts/check-agent-image.ts'), '--imp', `agent-check-${short}`],
    ['imp', 'rm', `agent-check-${short}`],
  ]);

  expect(src).toStartWith(join(tmpdir(), 'agent-image-build-'));
  expect(access(src)).rejects.toMatchObject({ code: 'ENOENT' });
});

test('it builds an older commit on main, and runs that commit’s bash check when it predates the bun one', async () => {
  const ctx = await setupTest();

  await mkdir(join(ctx.repo.seed, 'images/agent'), { recursive: true });
  await mkdir(join(ctx.repo.seed, 'scripts'));

  await writeFile(
    join(ctx.repo.seed, 'images/agent/Dockerfile'),
    'FROM ghcr.io/zgeoff/imp-base:0.33.0\n',
  );

  await writeFile(join(ctx.repo.seed, 'scripts/check-agent-image.sh'), '');

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the image']);

  const old = await ctx.repo.git(['-C', ctx.repo.seed, 'rev-parse', 'HEAD']);
  const short = await ctx.repo.git(['-C', ctx.repo.seed, 'rev-parse', '--short', 'HEAD']);

  await writeFile(
    join(ctx.repo.seed, 'images/agent/Dockerfile'),
    'FROM ghcr.io/zgeoff/imp-base:0.34.0\n',
  );

  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qam', 'bump imp-base']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'main']);
  await ctx.repo.git(['clone', '-q', ctx.repo.origin, ctx.clone]);

  const imp = buildStubImp({ images: [] });

  const stub = buildStubRunner(
    buildRealProgramHandler(['git', 'tar'], ctx.repo.env),
    imp.handler,
    buildStubCheckAgentImage(0),
  );

  const exitCode = await createAgentImage({
    args: [old],
    cwd: ctx.clone,
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  const check = stub.calls.find((call) => call.argv[0] === 'bash');

  expect(exitCode).toBe(0);
  expect(ctx.out).toStrictEqual([`agent-${short} imp-build-stub-agent-${short} check passed\n`]);
  expect(imp.builtDockerfiles).toStrictEqual(['FROM ghcr.io/zgeoff/imp-base:0.33.0\n']);
  expect(check?.argv.slice(2)).toStrictEqual(['--imp', `agent-check-${short}`]);
  expect(check?.argv[1]).toEndWith('/src/scripts/check-agent-image.sh');
});

test('it removes the image and the imp when the check fails', async () => {
  const ctx = await setupTest();

  await mkdir(join(ctx.repo.seed, 'images/agent'), { recursive: true });
  await mkdir(join(ctx.repo.seed, 'scripts'));

  await writeFile(
    join(ctx.repo.seed, 'images/agent/Dockerfile'),
    'FROM ghcr.io/zgeoff/imp-base:0.33.0\n',
  );

  await writeFile(join(ctx.repo.seed, 'scripts/check-agent-image.ts'), '');

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the image']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'main']);
  await ctx.repo.git(['clone', '-q', ctx.repo.origin, ctx.clone]);

  const sha = await ctx.repo.git(['-C', ctx.repo.seed, 'rev-parse', 'HEAD']);
  const short = await ctx.repo.git(['-C', ctx.repo.seed, 'rev-parse', '--short', 'HEAD']);

  const imp = buildStubImp({ images: [] });

  const stub = buildStubRunner(
    buildRealProgramHandler(['git', 'tar'], ctx.repo.env),
    imp.handler,
    buildStubCheckAgentImage(2),
  );

  const exitCode = await createAgentImage({
    args: [],
    cwd: ctx.clone,
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  const impCalls = stub.calls.filter((call) => call.argv[0] === 'imp');

  expect(exitCode).toBe(1);
  expect(ctx.out).toStrictEqual([`agent-${short} check failed; removed the image\n`]);

  expect(ctx.err.join('')).toBe(
    `building agent-${short} from ${sha}; imp image build shows no progress off a terminal\n` +
      `checking agent-${short} on a fresh imp, agent-check-${short}\n` +
      `agent-check-${short}\n` +
      '== 2 failed\n',
  );

  expect(imp.images).toStrictEqual([]);
  expect(imp.imps).toStrictEqual([]);

  expect(impCalls.slice(-2).map((call) => call.argv)).toStrictEqual([
    ['imp', 'rm', `agent-check-${short}`],
    ['imp', 'image', 'rm', `agent-${short}`],
  ]);
});

test('it keeps the image when the check fails with --keep', async () => {
  const ctx = await setupTest();

  await mkdir(join(ctx.repo.seed, 'images/agent'), { recursive: true });
  await mkdir(join(ctx.repo.seed, 'scripts'));

  await writeFile(
    join(ctx.repo.seed, 'images/agent/Dockerfile'),
    'FROM ghcr.io/zgeoff/imp-base:0.33.0\n',
  );

  await writeFile(join(ctx.repo.seed, 'scripts/check-agent-image.ts'), '');

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the image']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'main']);
  await ctx.repo.git(['clone', '-q', ctx.repo.origin, ctx.clone]);

  const short = await ctx.repo.git(['-C', ctx.repo.seed, 'rev-parse', '--short', 'HEAD']);

  const imp = buildStubImp({ images: [] });

  const stub = buildStubRunner(
    buildRealProgramHandler(['git', 'tar'], ctx.repo.env),
    imp.handler,
    buildStubCheckAgentImage(2),
  );

  const exitCode = await createAgentImage({
    args: ['--keep'],
    cwd: ctx.clone,
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);

  expect(ctx.out).toStrictEqual([
    `agent-${short} imp-build-stub-agent-${short} check failed; kept the image\n`,
  ]);

  expect(imp.images).toStrictEqual([
    { name: `agent-${short}`, digest: `imp-build-stub-agent-${short}` },
  ]);

  expect(imp.imps).toStrictEqual([]);
});

test('it fails without an imp when the build fails', async () => {
  const ctx = await setupTest();

  await mkdir(join(ctx.repo.seed, 'images/agent'), { recursive: true });
  await mkdir(join(ctx.repo.seed, 'scripts'));
  await writeFile(join(ctx.repo.seed, 'scripts/check-agent-image.ts'), '');

  await writeFile(
    join(ctx.repo.seed, 'images/agent/Dockerfile'),
    'FROM ghcr.io/zgeoff/imp-base:0.33.0\n',
  );

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the image']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'main']);
  await ctx.repo.git(['clone', '-q', ctx.repo.origin, ctx.clone]);

  const sha = await ctx.repo.git(['-C', ctx.repo.seed, 'rev-parse', 'HEAD']);
  const short = await ctx.repo.git(['-C', ctx.repo.seed, 'rev-parse', '--short', 'HEAD']);

  const imp = buildStubImp({ images: [], buildError: 'imp: BUILD_FAILED: the build exited 1' });
  const stub = buildStubRunner(buildRealProgramHandler(['git', 'tar'], ctx.repo.env), imp.handler);

  const exitCode = await createAgentImage({
    args: [],
    cwd: ctx.clone,
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);
  expect(ctx.out).toStrictEqual([]);

  expect(ctx.err.join('')).toBe(
    `building agent-${short} from ${sha}; imp image build shows no progress off a terminal\n` +
      'imp: BUILD_FAILED: the build exited 1\n' +
      `imp image build failed for agent-${short}\n`,
  );

  expect(imp.images).toStrictEqual([]);
  expect(imp.imps).toStrictEqual([]);
});

test('it fails when the build outlives AGENT_IMAGE_BUILD_TIMEOUT, and gives the build that timeout', async () => {
  const ctx = await setupTest();

  await mkdir(join(ctx.repo.seed, 'images/agent'), { recursive: true });
  await mkdir(join(ctx.repo.seed, 'scripts'));
  await writeFile(join(ctx.repo.seed, 'scripts/check-agent-image.ts'), '');

  await writeFile(
    join(ctx.repo.seed, 'images/agent/Dockerfile'),
    'FROM ghcr.io/zgeoff/imp-base:0.33.0\n',
  );

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the image']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'main']);
  await ctx.repo.git(['clone', '-q', ctx.repo.origin, ctx.clone]);

  const sha = await ctx.repo.git(['-C', ctx.repo.seed, 'rev-parse', 'HEAD']);
  const short = await ctx.repo.git(['-C', ctx.repo.seed, 'rev-parse', '--short', 'HEAD']);

  const imp = buildStubImp({ images: [], buildTimesOut: true });
  const stub = buildStubRunner(buildRealProgramHandler(['git', 'tar'], ctx.repo.env), imp.handler);

  const exitCode = await createAgentImage({
    args: [],
    cwd: ctx.clone,
    buildTimeout: '20m',
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  const build = stub.calls.find((call) => call.argv[2] === 'build');

  expect(exitCode).toBe(1);
  expect(build?.options.timeoutMs).toBe(1_200_000);

  expect(ctx.err.join('')).toBe(
    `building agent-${short} from ${sha}; imp image build shows no progress off a terminal\n` +
      `imp image build did not finish within 20m; impd may still finish agent-${short}, so read imp image ls before a retry\n`,
  );

  expect(imp.images).toStrictEqual([]);
});

test('it gives the build 45 minutes when AGENT_IMAGE_BUILD_TIMEOUT is unset', async () => {
  const ctx = await setupTest();

  await mkdir(join(ctx.repo.seed, 'images/agent'), { recursive: true });
  await mkdir(join(ctx.repo.seed, 'scripts'));
  await writeFile(join(ctx.repo.seed, 'scripts/check-agent-image.ts'), '');

  await writeFile(
    join(ctx.repo.seed, 'images/agent/Dockerfile'),
    'FROM ghcr.io/zgeoff/imp-base:0.33.0\n',
  );

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the image']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'main']);
  await ctx.repo.git(['clone', '-q', ctx.repo.origin, ctx.clone]);

  const imp = buildStubImp({ images: [], buildError: 'imp: BUILD_FAILED' });
  const stub = buildStubRunner(buildRealProgramHandler(['git', 'tar'], ctx.repo.env), imp.handler);

  await createAgentImage({
    args: [],
    cwd: ctx.clone,
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  const build = stub.calls.find((call) => call.argv[2] === 'build');

  expect(build?.options.timeoutMs).toBe(2_700_000);
});

test('it refuses a commit that is not on main, before any imp call', async () => {
  const ctx = await setupTest();

  await mkdir(join(ctx.repo.seed, 'images/agent'), { recursive: true });

  await writeFile(
    join(ctx.repo.seed, 'images/agent/Dockerfile'),
    'FROM ghcr.io/zgeoff/imp-base:0.33.0\n',
  );

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the image']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'main']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'switch', '-qc', 'topic']);

  await writeFile(
    join(ctx.repo.seed, 'images/agent/Dockerfile'),
    'FROM ghcr.io/zgeoff/imp-base:0.34.0\n',
  );

  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qam', 'bump imp-base']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'topic']);
  await ctx.repo.git(['clone', '-q', ctx.repo.origin, ctx.clone]);

  const sha = await ctx.repo.git(['-C', ctx.repo.seed, 'rev-parse', 'HEAD']);

  const imp = buildStubImp({ images: [] });
  const stub = buildStubRunner(buildRealProgramHandler(['git'], ctx.repo.env), imp.handler);

  const exitCode = await createAgentImage({
    args: ['origin/topic'],
    cwd: ctx.clone,
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);
  expect(ctx.out).toStrictEqual([]);

  expect(ctx.err).toStrictEqual([
    `${sha} is not on origin/main: build only a commit that main holds\n`,
  ]);

  expect(stub.calls.filter((call) => call.argv[0] === 'imp')).toStrictEqual([]);
});

test('it refuses an image name that is taken', async () => {
  const ctx = await setupTest();

  await mkdir(join(ctx.repo.seed, 'images/agent'), { recursive: true });

  await writeFile(
    join(ctx.repo.seed, 'images/agent/Dockerfile'),
    'FROM ghcr.io/zgeoff/imp-base:0.33.0\n',
  );

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the image']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'main']);
  await ctx.repo.git(['clone', '-q', ctx.repo.origin, ctx.clone]);

  const short = await ctx.repo.git(['-C', ctx.repo.seed, 'rev-parse', '--short', 'HEAD']);

  const imp = buildStubImp({ images: [{ name: `agent-${short}`, digest: 'imp-build-1' }] });
  const stub = buildStubRunner(buildRealProgramHandler(['git'], ctx.repo.env), imp.handler);

  const exitCode = await createAgentImage({
    args: [],
    cwd: ctx.clone,
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);

  expect(ctx.err).toStrictEqual([
    `image agent-${short} already exists: remove it with imp image rm, or build another commit\n`,
  ]);

  expect(
    stub.calls.filter((call) => call.argv[0] === 'imp').map((call) => call.argv),
  ).toStrictEqual([['imp', 'image', 'ls', '--json']]);

  expect(imp.images).toStrictEqual([{ name: `agent-${short}`, digest: 'imp-build-1' }]);
});

test('it refuses a check imp name that is taken', async () => {
  const ctx = await setupTest();

  await mkdir(join(ctx.repo.seed, 'images/agent'), { recursive: true });

  await writeFile(
    join(ctx.repo.seed, 'images/agent/Dockerfile'),
    'FROM ghcr.io/zgeoff/imp-base:0.33.0\n',
  );

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the image']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'main']);
  await ctx.repo.git(['clone', '-q', ctx.repo.origin, ctx.clone]);

  const short = await ctx.repo.git(['-C', ctx.repo.seed, 'rev-parse', '--short', 'HEAD']);

  const imp = buildStubImp({
    images: [{ name: 'agent-1', digest: 'imp-build-1' }],
    imps: [{ name: `agent-check-${short}`, image: 'agent-1' }],
  });

  const stub = buildStubRunner(buildRealProgramHandler(['git'], ctx.repo.env), imp.handler);

  const exitCode = await createAgentImage({
    args: [],
    cwd: ctx.clone,
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);

  expect(ctx.err).toStrictEqual([
    `imp agent-check-${short} already exists: remove it with imp rm first\n`,
  ]);

  expect(
    stub.calls.filter((call) => call.argv[0] === 'imp').map((call) => call.argv),
  ).toStrictEqual([
    ['imp', 'image', 'ls', '--json'],
    ['imp', 'ls', '--json'],
  ]);
});

test.each([
  ['an unknown option', ['--switch']],
  ['two commits', ['abc1234', 'def5678']],
  ['--keep after the commit', ['abc1234', '--keep']],
] as const)('it prints its usage and exits 2 for %s', async (_label, args) => {
  const ctx = await setupTest();

  const stub = buildStubRunner();

  const exitCode = await createAgentImage({
    args,
    cwd: ctx.dir,
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(2);
  expect(ctx.err).toStrictEqual(['usage: build-agent-image.ts [--keep] [<commit on main>]\n']);
  expect(stub.calls).toStrictEqual([]);
});

test('it refuses an AGENT_IMAGE_BUILD_TIMEOUT that is not a duration, before any call', async () => {
  const ctx = await setupTest();

  const stub = buildStubRunner();

  const exitCode = await createAgentImage({
    args: [],
    cwd: ctx.dir,
    buildTimeout: '45 minutes',
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(2);

  expect(ctx.err).toStrictEqual([
    "AGENT_IMAGE_BUILD_TIMEOUT holds '45 minutes', not a duration such as 45m\n",
  ]);

  expect(stub.calls).toStrictEqual([]);
});
