import { expect, onTestFinished, test } from 'bun:test';
import { access, mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { createFakeClock } from '@zgeoff/testing/clock';
import { recordAgentImageRetention } from './agent-image-retention-state.ts';
import { createAgentImage } from './create-agent-image.ts';
import { buildRealProgramHandler } from './src/test-utils/build-real-program-handler.ts';
import { buildStubCheckAgentImage } from './src/test-utils/build-stub-check-agent-image.ts';
import { buildStubImp } from './src/test-utils/build-stub-imp.ts';
import { buildStubRunner } from './src/test-utils/build-stub-runner.ts';
import { createSeededGitOrigin } from './src/test-utils/create-seeded-git-origin.ts';
import { switchAgentImage } from './switch-agent-image.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'create-agent-image-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  const repo = await createSeededGitOrigin(directory);

  const out: string[] = [];
  const err: string[] = [];
  const clone = join(directory, 'clone');

  // the clone of a main whose NixOS file names each image in its own commit
  const createClone = async (nixImages: string[]) => {
    await mkdir(join(repo.seed, 'images/agent'), { recursive: true });
    await mkdir(join(repo.seed, 'scripts'));
    await mkdir(join(repo.seed, 'nixos/hosts/geoffcloud'), { recursive: true });
    await writeFile(join(repo.seed, '.bun-version'), '1.4.9\n');

    await writeFile(
      join(repo.seed, 'images/agent/Dockerfile'),
      'FROM ghcr.io/zgeoff/imp-base:0.33.0\n',
    );

    await writeFile(join(repo.seed, 'scripts/check-agent-image.ts'), '');

    for (const image of nixImages) {
      // oxlint-disable-next-line no-await-in-loop
      await writeFile(
        join(repo.seed, 'nixos/hosts/geoffcloud/configuration.nix'),
        `      image = "${image}";\n`,
      );

      // oxlint-disable-next-line no-await-in-loop
      await repo.git(['-C', repo.seed, 'add', '-A']);
      // oxlint-disable-next-line no-await-in-loop
      await repo.git(['-C', repo.seed, 'commit', '-qm', `set ${image}`]);

      // the host runs the first of the images
      if (image === nixImages[0]) {
        // oxlint-disable-next-line no-await-in-loop
        await repo.git(['-C', repo.seed, 'tag', 'deployed/host']);
      }
    }

    await repo.git(['-C', repo.seed, 'push', '-q', 'origin', 'main', 'deployed/host']);
    await repo.git(['clone', '-q', repo.origin, clone]);
  };

  return {
    directory,
    repo,
    clone,
    createClone,
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

test('it builds the head of main from its archive, checks it on a fresh imp, removes the imp, and pins the image', async () => {
  const ctx = await setupTest();

  await mkdir(join(ctx.repo.seed, 'images/agent'), { recursive: true });
  await mkdir(join(ctx.repo.seed, 'scripts'));
  await mkdir(join(ctx.repo.seed, 'nixos/hosts/geoffcloud'), { recursive: true });
  await writeFile(join(ctx.repo.seed, '.bun-version'), '1.4.9\n');

  await writeFile(
    join(ctx.repo.seed, 'nixos/hosts/geoffcloud/configuration.nix'),
    '      image = "agent-1111111";\n',
  );

  await writeFile(
    join(ctx.repo.seed, 'images/agent/Dockerfile'),
    'FROM ghcr.io/zgeoff/imp-base:0.33.0\n',
  );

  await writeFile(join(ctx.repo.seed, 'scripts/check-agent-image.ts'), '');

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the image']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'tag', 'deployed/host']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'main', 'deployed/host']);
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
    registerCleanup: () => () => {},
  });

  const impCalls = stub.calls.filter((call) => call.argv[0] !== 'git' && call.argv[0] !== 'tar');
  const source = dirname(dirname(impCalls[2]?.argv[3] ?? ''));

  expect(exitCode).toBe(0);
  expect(ctx.out).toStrictEqual([`agent-${short} imp-build-stub-agent-${short} check passed\n`]);

  expect(ctx.err.join('')).toBe(
    `building agent-${short} from ${sha}; impz image build shows no progress off a terminal\n` +
      `checking agent-${short} on a fresh imp, agent-check-${short}\n` +
      `agent-check-${short}\n` +
      '== 0 failed\n',
  );

  expect(imp.builtDockerfiles).toStrictEqual(['FROM ghcr.io/zgeoff/imp-base:0.33.0\n']);

  expect(imp.images).toStrictEqual([
    { name: `agent-${short}`, digest: `imp-build-stub-agent-${short}`, isPinned: true },
  ]);

  expect(imp.imps).toStrictEqual([]);

  expect(impCalls.map((call) => call.argv)).toStrictEqual([
    ['impz', 'image', 'ls', '--json'],
    ['impz', 'ls', '--json'],
    ['impz', 'image', 'build', join(source, 'images/agent'), '--name', `agent-${short}`],
    ['impz', 'image', 'ls', '--json'],
    [
      'impz',
      'new',
      `agent-check-${short}`,
      '--image',
      `agent-${short}`,
      '--memory',
      '1024',
      '--max-memory',
      '2048',
    ],
    ['bun', join(source, 'scripts/check-agent-image.ts'), '--imp', `agent-check-${short}`],
    ['impz', 'rm', `agent-check-${short}`],
    ['impz', 'image', 'pin', `agent-${short}`],
    ['impz', 'image', 'ls', '--json'],
  ]);

  expect(source).toStartWith(join(tmpdir(), 'agent-image-build-'));
  expect(access(source)).rejects.toMatchObject({ code: 'ENOENT' });
});

test('it builds an older commit on main, and runs that commit’s bash check when it predates the bun one', async () => {
  const ctx = await setupTest();

  await mkdir(join(ctx.repo.seed, 'images/agent'), { recursive: true });
  await mkdir(join(ctx.repo.seed, 'scripts'));
  await writeFile(join(ctx.repo.seed, '.bun-version'), '1.4.9\n');

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
    registerCleanup: () => () => {},
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
  await writeFile(join(ctx.repo.seed, '.bun-version'), '1.4.9\n');

  await writeFile(
    join(ctx.repo.seed, 'images/agent/Dockerfile'),
    'FROM ghcr.io/zgeoff/imp-base:0.33.0\n',
  );

  await writeFile(join(ctx.repo.seed, 'scripts/check-agent-image.ts'), '');

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the image']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'tag', 'deployed/host']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'main', 'deployed/host']);
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
    registerCleanup: () => () => {},
  });

  const impCalls = stub.calls.filter((call) => call.argv[0] === 'impz');

  expect(exitCode).toBe(1);
  expect(ctx.out).toStrictEqual([`agent-${short} check failed; removed the image\n`]);

  expect(ctx.err.join('')).toBe(
    `building agent-${short} from ${sha}; impz image build shows no progress off a terminal\n` +
      `checking agent-${short} on a fresh imp, agent-check-${short}\n` +
      `agent-check-${short}\n` +
      '== 2 failed\n',
  );

  expect(imp.images).toStrictEqual([]);
  expect(imp.imps).toStrictEqual([]);

  expect(impCalls.slice(-2).map((call) => call.argv)).toStrictEqual([
    ['impz', 'rm', `agent-check-${short}`],
    ['impz', 'image', 'rm', `agent-${short}`],
  ]);
});

test('it keeps the image when the check fails with --keep', async () => {
  const ctx = await setupTest();

  await mkdir(join(ctx.repo.seed, 'images/agent'), { recursive: true });
  await mkdir(join(ctx.repo.seed, 'scripts'));
  await writeFile(join(ctx.repo.seed, '.bun-version'), '1.4.9\n');

  await writeFile(
    join(ctx.repo.seed, 'images/agent/Dockerfile'),
    'FROM ghcr.io/zgeoff/imp-base:0.33.0\n',
  );

  await writeFile(join(ctx.repo.seed, 'scripts/check-agent-image.ts'), '');

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the image']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'tag', 'deployed/host']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'main', 'deployed/host']);
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
    registerCleanup: () => () => {},
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
  await writeFile(join(ctx.repo.seed, '.bun-version'), '1.4.9\n');
  await writeFile(join(ctx.repo.seed, 'scripts/check-agent-image.ts'), '');

  await writeFile(
    join(ctx.repo.seed, 'images/agent/Dockerfile'),
    'FROM ghcr.io/zgeoff/imp-base:0.33.0\n',
  );

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the image']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'tag', 'deployed/host']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'main', 'deployed/host']);
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
    registerCleanup: () => () => {},
  });

  expect(exitCode).toBe(1);
  expect(ctx.out).toStrictEqual([]);

  expect(ctx.err.join('')).toBe(
    `building agent-${short} from ${sha}; impz image build shows no progress off a terminal\n` +
      'imp: BUILD_FAILED: the build exited 1\n' +
      `impz image build failed for agent-${short}\n`,
  );

  expect(imp.images).toStrictEqual([]);
  expect(imp.imps).toStrictEqual([]);
});

test('it leaves the image to an interrupt from the build on, newest of the steps', async () => {
  const ctx = await setupTest();

  await mkdir(join(ctx.repo.seed, 'images/agent'), { recursive: true });
  await mkdir(join(ctx.repo.seed, 'scripts'));
  await writeFile(join(ctx.repo.seed, '.bun-version'), '1.4.9\n');
  await writeFile(join(ctx.repo.seed, 'scripts/check-agent-image.ts'), '');
  await writeFile(join(ctx.repo.seed, 'images/agent/Dockerfile'), 'FROM scratch\n');

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the image']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'tag', 'deployed/host']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'main', 'deployed/host']);
  await ctx.repo.git(['clone', '-q', ctx.repo.origin, ctx.clone]);

  const short = await ctx.repo.git(['-C', ctx.repo.seed, 'rev-parse', '--short', 'HEAD']);

  const steps: (() => unknown)[] = [];
  const interrupt = buildStubRunner(() => ({}));
  const imp = buildStubImp({ images: [] });

  // runs the newest step while the build runs, since the older one removes the build's directory
  const stub = buildStubRunner(
    buildRealProgramHandler(['git', 'tar'], ctx.repo.env),
    async (call) => {
      if (call.argv[1] === 'image' && call.argv[2] === 'build') {
        await steps.at(-1)?.();
      }
    },
    imp.handler,
    buildStubCheckAgentImage(0),
  );

  const exitCode = await createAgentImage({
    args: [],
    cwd: ctx.clone,
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
    registerCleanup: (step) => {
      steps.push(() => step({ run: interrupt.run, printOut() {}, printErr() {} }));

      return () => {};
    },
  });

  expect(exitCode).toBe(0);

  expect(interrupt.calls.map((call) => call.argv)).toStrictEqual([
    ['impz', 'image', 'rm', `agent-${short}`],
  ]);
});

test('it fails when the build outlives AGENT_IMAGE_BUILD_TIMEOUT, and gives the build that timeout', async () => {
  const ctx = await setupTest();

  await mkdir(join(ctx.repo.seed, 'images/agent'), { recursive: true });
  await mkdir(join(ctx.repo.seed, 'scripts'));
  await writeFile(join(ctx.repo.seed, '.bun-version'), '1.4.9\n');
  await writeFile(join(ctx.repo.seed, 'scripts/check-agent-image.ts'), '');

  await writeFile(
    join(ctx.repo.seed, 'images/agent/Dockerfile'),
    'FROM ghcr.io/zgeoff/imp-base:0.33.0\n',
  );

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the image']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'tag', 'deployed/host']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'main', 'deployed/host']);
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
    registerCleanup: () => () => {},
  });

  const build = stub.calls.find((call) => call.argv[2] === 'build');

  expect(exitCode).toBe(1);
  expect(build?.options.timeoutMs).toBe(1_200_000);

  expect(ctx.err.join('')).toBe(
    `building agent-${short} from ${sha}; impz image build shows no progress off a terminal\n` +
      `impz image build did not finish within 20m; impd may still finish agent-${short}, so read impz image ls before a retry\n`,
  );

  expect(imp.images).toStrictEqual([]);
});

test('it gives the build 45 minutes when AGENT_IMAGE_BUILD_TIMEOUT is unset', async () => {
  const ctx = await setupTest();

  await mkdir(join(ctx.repo.seed, 'images/agent'), { recursive: true });
  await mkdir(join(ctx.repo.seed, 'scripts'));
  await writeFile(join(ctx.repo.seed, '.bun-version'), '1.4.9\n');
  await writeFile(join(ctx.repo.seed, 'scripts/check-agent-image.ts'), '');

  await writeFile(
    join(ctx.repo.seed, 'images/agent/Dockerfile'),
    'FROM ghcr.io/zgeoff/imp-base:0.33.0\n',
  );

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the image']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'tag', 'deployed/host']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'main', 'deployed/host']);
  await ctx.repo.git(['clone', '-q', ctx.repo.origin, ctx.clone]);

  const imp = buildStubImp({ images: [], buildError: 'imp: BUILD_FAILED' });
  const stub = buildStubRunner(buildRealProgramHandler(['git', 'tar'], ctx.repo.env), imp.handler);

  await createAgentImage({
    args: [],
    cwd: ctx.clone,
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
    registerCleanup: () => () => {},
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
  await ctx.repo.git(['-C', ctx.repo.seed, 'tag', 'deployed/host']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'main', 'deployed/host']);
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
    registerCleanup: () => () => {},
  });

  expect(exitCode).toBe(1);
  expect(ctx.out).toStrictEqual([]);

  expect(ctx.err).toStrictEqual([
    `${sha} is not on origin/main: build only a commit that main holds\n`,
  ]);

  expect(stub.calls.filter((call) => call.argv[0] === 'impz')).toStrictEqual([]);
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
  await ctx.repo.git(['-C', ctx.repo.seed, 'tag', 'deployed/host']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'main', 'deployed/host']);
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
    registerCleanup: () => () => {},
  });

  expect(exitCode).toBe(1);

  expect(ctx.err).toStrictEqual([
    `image agent-${short} already exists: remove it with impz image rm, or build another commit\n`,
  ]);

  expect(
    stub.calls.filter((call) => call.argv[0] === 'impz').map((call) => call.argv),
  ).toStrictEqual([['impz', 'image', 'ls', '--json']]);

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
  await ctx.repo.git(['-C', ctx.repo.seed, 'tag', 'deployed/host']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'main', 'deployed/host']);
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
    registerCleanup: () => () => {},
  });

  expect(exitCode).toBe(1);

  expect(ctx.err).toStrictEqual([
    `imp agent-check-${short} already exists: remove it with impz rm first\n`,
  ]);

  expect(
    stub.calls.filter((call) => call.argv[0] === 'impz').map((call) => call.argv),
  ).toStrictEqual([
    ['impz', 'image', 'ls', '--json'],
    ['impz', 'ls', '--json'],
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
    cwd: ctx.directory,
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
    registerCleanup: () => () => {},
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
    cwd: ctx.directory,
    buildTimeout: '45 minutes',
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
    registerCleanup: () => () => {},
  });

  expect(exitCode).toBe(2);

  expect(ctx.err).toStrictEqual([
    "AGENT_IMAGE_BUILD_TIMEOUT holds '45 minutes', not a duration such as 45m\n",
  ]);

  expect(stub.calls).toStrictEqual([]);
});

test('it unpins every older agent image except the newest passing one, the target images and the new one', async () => {
  const ctx = await setupTest();

  await mkdir(join(ctx.repo.seed, 'images/agent'), { recursive: true });
  await mkdir(join(ctx.repo.seed, 'scripts'));
  await mkdir(join(ctx.repo.seed, 'nixos/hosts/geoffcloud'), { recursive: true });
  await writeFile(join(ctx.repo.seed, '.bun-version'), '1.4.9\n');

  await writeFile(
    join(ctx.repo.seed, 'images/agent/Dockerfile'),
    'FROM ghcr.io/zgeoff/imp-base:0.33.0\n',
  );

  await writeFile(join(ctx.repo.seed, 'scripts/check-agent-image.ts'), '');

  await writeFile(
    join(ctx.repo.seed, 'nixos/hosts/geoffcloud/configuration.nix'),
    '      image = "agent-1111111";\n',
  );

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the image']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'tag', 'deployed/host']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'main', 'deployed/host']);
  await ctx.repo.git(['clone', '-q', ctx.repo.origin, ctx.clone]);

  await mkdir(join(ctx.directory, 'home/.config/atc'), { recursive: true });

  await writeFile(
    join(ctx.directory, 'home/.config/atc/config.json'),
    JSON.stringify({ targets: { cloud: { provider: 'imp', image: 'agent-2222222' } } }),
  );

  const short = await ctx.repo.git(['-C', ctx.repo.seed, 'rev-parse', '--short', 'HEAD']);

  const images = [1, 2, 3, 4, 5].map((day) => ({
    name: `agent-${String(day).repeat(7)}`,
    digest: `imp-build-${day}`,
    isPinned: true,
    createdAt: `2026-11-0${day}T00:00:00Z`,
  }));

  const imp = buildStubImp({ images });

  const stub = buildStubRunner(
    buildRealProgramHandler(['git', 'tar'], ctx.repo.env),
    imp.handler,
    buildStubCheckAgentImage(0),
  );

  const exitCode = await createAgentImage({
    args: [],
    cwd: ctx.clone,
    home: join(ctx.directory, 'home'),
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
    registerCleanup: () => () => {},
  });

  const unpinCalls = stub.calls.filter((call) => call.argv[2] === 'unpin');

  expect(exitCode).toBe(0);

  expect(unpinCalls.map((call) => call.argv)).toStrictEqual([
    ['impz', 'image', 'unpin', 'agent-3333333'],
    ['impz', 'image', 'unpin', 'agent-4444444'],
  ]);

  expect(
    imp.images.filter((image) => image.isPinned === true).map((image) => image.name),
  ).toStrictEqual(['agent-1111111', 'agent-2222222', 'agent-5555555', `agent-${short}`]);
});

test('it logs an unpin that fails, goes on to the next image, and still passes the build', async () => {
  const ctx = await setupTest();

  await mkdir(join(ctx.repo.seed, 'images/agent'), { recursive: true });
  await mkdir(join(ctx.repo.seed, 'scripts'));
  await mkdir(join(ctx.repo.seed, 'nixos/hosts/geoffcloud'), { recursive: true });
  await writeFile(join(ctx.repo.seed, '.bun-version'), '1.4.9\n');

  await writeFile(
    join(ctx.repo.seed, 'images/agent/Dockerfile'),
    'FROM ghcr.io/zgeoff/imp-base:0.33.0\n',
  );

  await writeFile(join(ctx.repo.seed, 'scripts/check-agent-image.ts'), '');

  await writeFile(
    join(ctx.repo.seed, 'nixos/hosts/geoffcloud/configuration.nix'),
    '      image = "agent-1111111";\n',
  );

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the image']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'tag', 'deployed/host']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'main', 'deployed/host']);
  await ctx.repo.git(['clone', '-q', ctx.repo.origin, ctx.clone]);

  const images = [1, 2, 3, 4, 5].map((day) => ({
    name: `agent-${String(day).repeat(7)}`,
    digest: `imp-build-${day}`,
    isPinned: true,
    createdAt: `2026-11-0${day}T00:00:00Z`,
  }));

  const imp = buildStubImp({ images });

  const stub = buildStubRunner(
    (call) =>
      call.argv.join(' ') === 'impz image unpin agent-3333333'
        ? { exitCode: 1, stderr: 'impz: NOT_FOUND: image agent-3333333 not found\n' }
        : undefined,
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
    registerCleanup: () => () => {},
  });

  expect({
    exitCode,
    unpinLogs: ctx.err.filter((line) => line.includes('unpin')),
  }).toStrictEqual({
    exitCode: 0,
    unpinLogs: [
      'unpinned agent-2222222; impd may evict it when it frees disk\n',
      'could not unpin agent-3333333: impz: NOT_FOUND: image agent-3333333 not found\n',
      'unpinned agent-4444444; impd may evict it when it frees disk\n',
    ],
  });
});

test('it keeps the image of a target that the host config named in an earlier commit', async () => {
  const ctx = await setupTest();

  await ctx.createClone(['agent-1111111', 'agent-4444444']);

  const imp = buildStubImp({
    images: Array.from({ length: 5 }, (_unused, index) => ({
      name: `agent-${String(index + 1).repeat(7)}`,
      digest: `imp-build-${index + 1}`,
      isPinned: true,
      createdAt: `2026-11-0${index + 1}T00:00:00Z`,
    })),
  });

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
    registerCleanup: () => () => {},
  });

  const unpinCalls = stub.calls.filter((call) => call.argv[2] === 'unpin');

  expect(exitCode).toBe(0);
  expect(unpinCalls.map((call) => call.argv[3])).toStrictEqual(['agent-2222222', 'agent-3333333']);
});

test('it keeps every image pinned when a target config is not JSON', async () => {
  const ctx = await setupTest();

  await ctx.createClone(['agent-1111111']);

  const config = join(ctx.directory, 'custom-atc.json');

  await writeFile(config, '{ broken');

  const imp = buildStubImp({
    images: Array.from({ length: 4 }, (_unused, index) => ({
      name: `agent-${String(index + 1).repeat(7)}`,
      digest: `imp-build-${index + 1}`,
      isPinned: true,
      createdAt: `2026-11-0${index + 1}T00:00:00Z`,
    })),
  });

  const stub = buildStubRunner(
    buildRealProgramHandler(['git', 'tar'], ctx.repo.env),
    imp.handler,
    buildStubCheckAgentImage(0),
  );

  const exitCode = await createAgentImage({
    args: [],
    cwd: ctx.clone,
    targetConfigs: [config],
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
    registerCleanup: () => () => {},
  });

  expect(exitCode).toBe(0);
  expect(stub.calls.filter((call) => call.argv[2] === 'unpin')).toStrictEqual([]);
  expect(ctx.err.join('')).toInclude('kept every agent image pinned');
});

test('it reads the targets of a custom atc config file', async () => {
  const ctx = await setupTest();

  await ctx.createClone(['agent-1111111']);

  const config = join(ctx.directory, 'custom-atc.json');

  await writeFile(config, JSON.stringify({ targets: { lab: { image: 'agent-2222222' } } }));

  const imp = buildStubImp({
    images: Array.from({ length: 4 }, (_unused, index) => ({
      name: `agent-${String(index + 1).repeat(7)}`,
      digest: `imp-build-${index + 1}`,
      isPinned: true,
      createdAt: `2026-11-0${index + 1}T00:00:00Z`,
    })),
  });

  const stub = buildStubRunner(
    buildRealProgramHandler(['git', 'tar'], ctx.repo.env),
    imp.handler,
    buildStubCheckAgentImage(0),
  );

  await createAgentImage({
    args: [],
    cwd: ctx.clone,
    targetConfigs: [config],
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
    registerCleanup: () => () => {},
  });

  expect(
    stub.calls.filter((call) => call.argv[2] === 'unpin').map((call) => call.argv[3]),
  ).toStrictEqual(['agent-3333333']);
});

test('it goes on to the next unpin when the runner rejects one', async () => {
  const ctx = await setupTest();

  await ctx.createClone(['agent-1111111']);

  const imp = buildStubImp({
    images: Array.from({ length: 5 }, (_unused, index) => ({
      name: `agent-${String(index + 1).repeat(7)}`,
      digest: `imp-build-${index + 1}`,
      isPinned: true,
      createdAt: `2026-11-0${index + 1}T00:00:00Z`,
    })),
  });

  const stub = buildStubRunner(
    (call) =>
      call.argv.join(' ') === 'impz image unpin agent-2222222'
        ? Promise.reject(new Error('spawn failed'))
        : undefined,
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
    registerCleanup: () => () => {},
  });

  expect(exitCode).toBe(0);
  expect(ctx.err.join('')).toInclude('could not unpin agent-2222222: spawn failed');
  expect(ctx.err.join('')).toInclude('unpinned agent-3333333');
});

test('it pins an image again when a target names it while the unpins run', async () => {
  const ctx = await setupTest();

  await ctx.createClone(['agent-1111111']);

  const config = join(ctx.directory, 'custom-atc.json');

  const imp = buildStubImp({
    images: Array.from({ length: 5 }, (_unused, index) => ({
      name: `agent-${String(index + 1).repeat(7)}`,
      digest: `imp-build-${index + 1}`,
      isPinned: true,
      createdAt: `2026-11-0${index + 1}T00:00:00Z`,
    })),
  });

  const stub = buildStubRunner(
    buildRealProgramHandler(['git', 'tar'], ctx.repo.env),
    imp.handler,
    buildStubCheckAgentImage(0),
  );

  await createAgentImage({
    args: [],
    cwd: ctx.clone,
    targetConfigs: [config],
    run: async (argv, options) => {
      const result = await stub.run(argv, options);

      // a switch writes its config just after the unpin
      if (argv.join(' ') === 'impz image unpin agent-2222222') {
        await writeFile(config, JSON.stringify({ targets: { cloud: { image: 'agent-2222222' } } }));
      }

      return result;
    },
    printOut: ctx.printOut,
    printErr: ctx.printErr,
    registerCleanup: () => () => {},
  });

  expect(imp.images.find((image) => image.name === 'agent-2222222')?.isPinned).toBe(true);
  expect(ctx.err.join('')).toInclude('pinned agent-2222222 again');
});

test('it does not remove the passing image when an interrupt lands during the unpins', async () => {
  const ctx = await setupTest();

  await ctx.createClone(['agent-1111111']);

  let armed = false;
  const armedAtUnpin: boolean[] = [];

  const imp = buildStubImp({
    images: Array.from({ length: 5 }, (_unused, index) => ({
      name: `agent-${String(index + 1).repeat(7)}`,
      digest: `imp-build-${index + 1}`,
      isPinned: true,
      createdAt: `2026-11-0${index + 1}T00:00:00Z`,
    })),
  });

  const stub = buildStubRunner(
    buildRealProgramHandler(['git', 'tar'], ctx.repo.env),
    imp.handler,
    buildStubCheckAgentImage(0),
  );

  const exitCode = await createAgentImage({
    args: [],
    cwd: ctx.clone,
    run: (argv, options) => {
      if (argv[2] === 'unpin') {
        armedAtUnpin.push(armed);
      }

      return stub.run(argv, options);
    },
    printOut: ctx.printOut,
    printErr: ctx.printErr,
    registerCleanup: () => {
      armed = true;

      return () => {
        armed = false;
      };
    },
  });

  expect(exitCode).toBe(0);
  expect(armedAtUnpin).toStrictEqual([false, false, false]);
});

test('it keeps the image of a target whose config a switch recorded, without AGENT_IMAGE_TARGET_CONFIGS', async () => {
  const ctx = await setupTest();

  await ctx.createClone(['agent-1111111']);

  const home = join(ctx.directory, 'home');
  const config = join(ctx.directory, 'lab-atc.json');

  await writeFile(config, JSON.stringify({ targets: { cloud: { image: 'agent-2222222' } } }));
  await recordAgentImageRetention(home, { config });

  const imp = buildStubImp({
    images: Array.from({ length: 4 }, (_unused, index) => ({
      name: `agent-${String(index + 1).repeat(7)}`,
      digest: `imp-build-${index + 1}`,
      isPinned: true,
      createdAt: `2026-11-0${index + 1}T00:00:00Z`,
    })),
  });

  const stub = buildStubRunner(
    buildRealProgramHandler(['git', 'tar'], ctx.repo.env),
    imp.handler,
    buildStubCheckAgentImage(0),
  );

  const exitCode = await createAgentImage({
    args: [],
    cwd: ctx.clone,
    home,
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
    registerCleanup: () => () => {},
  });

  expect(exitCode).toBe(0);

  expect(
    stub.calls.filter((call) => call.argv[2] === 'unpin').map((call) => call.argv[3]),
  ).toStrictEqual(['agent-3333333']);
});

test('it keeps the image of a host that runs a config many commits older than main', async () => {
  const ctx = await setupTest();

  await ctx.createClone([
    'agent-1111111',
    'agent-2222222',
    'agent-3333333',
    'agent-4444444',
    'agent-5555555',
  ]);

  const imp = buildStubImp({
    images: Array.from({ length: 5 }, (_unused, index) => ({
      name: `agent-${String(index + 1).repeat(7)}`,
      digest: `imp-build-${index + 1}`,
      isPinned: true,
      createdAt: `2026-11-0${index + 1}T00:00:00Z`,
    })),
  });

  const stub = buildStubRunner(
    buildRealProgramHandler(['git', 'tar'], ctx.repo.env),
    imp.handler,
    buildStubCheckAgentImage(0),
  );

  await createAgentImage({
    args: [],
    cwd: ctx.clone,
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
    registerCleanup: () => () => {},
  });

  expect(
    imp.images.filter((image) => image.isPinned === true).map((image) => image.name),
  ).toContain('agent-1111111');
});

test('it keeps every image pinned when the deployed host tag cannot be fetched', async () => {
  const ctx = await setupTest();

  await ctx.createClone(['agent-1111111']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', ':refs/tags/deployed/host']);

  const imp = buildStubImp({
    images: Array.from({ length: 4 }, (_unused, index) => ({
      name: `agent-${String(index + 1).repeat(7)}`,
      digest: `imp-build-${index + 1}`,
      isPinned: true,
      createdAt: `2026-11-0${index + 1}T00:00:00Z`,
    })),
  });

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
    registerCleanup: () => () => {},
  });

  expect(exitCode).toBe(0);
  expect(stub.calls.filter((call) => call.argv[2] === 'unpin')).toStrictEqual([]);
  expect(ctx.err.join('')).toInclude('kept every agent image pinned: git fetch of deployed/host');
});

test('it counts an image that only a switch pinned as no passing image once its target moved away', async () => {
  const ctx = await setupTest();

  await ctx.createClone(['agent-1111111']);

  const home = join(ctx.directory, 'home');

  await recordAgentImageRetention(home, { switchOnlyImage: 'agent-3333333' });

  const imp = buildStubImp({
    images: Array.from({ length: 4 }, (_unused, index) => ({
      name: `agent-${String(index + 1).repeat(7)}`,
      digest: `imp-build-${index + 1}`,
      isPinned: true,
      createdAt: `2026-11-0${index + 1}T00:00:00Z`,
    })),
  });

  const stub = buildStubRunner(
    buildRealProgramHandler(['git', 'tar'], ctx.repo.env),
    imp.handler,
    buildStubCheckAgentImage(0),
  );

  await createAgentImage({
    args: [],
    cwd: ctx.clone,
    home,
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
    registerCleanup: () => () => {},
  });

  expect(
    stub.calls.filter((call) => call.argv[2] === 'unpin').map((call) => call.argv[3]),
  ).toStrictEqual(['agent-2222222', 'agent-3333333']);

  expect(imp.images.find((image) => image.name === 'agent-4444444')?.isPinned).toBe(true);
});

test('it tries again when impd refuses the pin that repairs an unpin a switch overtook', async () => {
  const ctx = await setupTest();

  await ctx.createClone(['agent-1111111']);

  const config = join(ctx.directory, 'custom-atc.json');

  const imp = buildStubImp({
    images: Array.from({ length: 5 }, (_unused, index) => ({
      name: `agent-${String(index + 1).repeat(7)}`,
      digest: `imp-build-${index + 1}`,
      isPinned: true,
      createdAt: `2026-11-0${index + 1}T00:00:00Z`,
    })),
  });

  const stub = buildStubRunner(
    buildRealProgramHandler(['git', 'tar'], ctx.repo.env),
    imp.handler,
    buildStubCheckAgentImage(0),
  );

  let pins = 0;

  const exitCode = await createAgentImage({
    args: [],
    cwd: ctx.clone,
    targetConfigs: [config],
    run: async (argv, options) => {
      if (argv.join(' ') === 'impz image pin agent-2222222') {
        pins += 1;

        if (pins <= 1) {
          return {
            exitCode: 1,
            stdout: Buffer.from(''),
            stderr: Buffer.from('impz: pin refused\n'),
            timedOut: false,
          };
        }
      }

      const result = await stub.run(argv, options);

      // a switch writes its config just after the unpin
      if (argv.join(' ') === 'impz image unpin agent-2222222') {
        await writeFile(config, JSON.stringify({ targets: { cloud: { image: 'agent-2222222' } } }));
      }

      return result;
    },
    printOut: ctx.printOut,
    printErr: ctx.printErr,
    registerCleanup: () => () => {},
  });

  expect({
    exitCode,
    pinned: imp.images.find((image) => image.name === 'agent-2222222')?.isPinned,
  }).toStrictEqual({
    exitCode: 0,
    pinned: true,
  });
});

test('it fails the build and names the image when impd keeps refusing the repairing pin', async () => {
  const ctx = await setupTest();

  await ctx.createClone(['agent-1111111']);

  const config = join(ctx.directory, 'custom-atc.json');

  const imp = buildStubImp({
    images: Array.from({ length: 5 }, (_unused, index) => ({
      name: `agent-${String(index + 1).repeat(7)}`,
      digest: `imp-build-${index + 1}`,
      isPinned: true,
      createdAt: `2026-11-0${index + 1}T00:00:00Z`,
    })),
  });

  const stub = buildStubRunner(
    buildRealProgramHandler(['git', 'tar'], ctx.repo.env),
    imp.handler,
    buildStubCheckAgentImage(0),
  );

  let pins = 0;

  const exitCode = await createAgentImage({
    args: [],
    cwd: ctx.clone,
    targetConfigs: [config],
    run: async (argv, options) => {
      if (argv.join(' ') === 'impz image pin agent-2222222') {
        pins += 1;

        if (pins >= 1) {
          return {
            exitCode: 1,
            stdout: Buffer.from(''),
            stderr: Buffer.from('impz: pin refused\n'),
            timedOut: false,
          };
        }
      }

      const result = await stub.run(argv, options);

      // a switch writes its config just after the unpin
      if (argv.join(' ') === 'impz image unpin agent-2222222') {
        await writeFile(config, JSON.stringify({ targets: { cloud: { image: 'agent-2222222' } } }));
      }

      return result;
    },
    printOut: ctx.printOut,
    printErr: ctx.printErr,
    registerCleanup: () => () => {},
  });

  expect({ exitCode, stderr: ctx.err.join('') }).toStrictEqual({
    exitCode: 1,
    stderr: expect.toInclude('a target boots agent-2222222 but impd refused to pin it again'),
  });
});

test('it keeps the image of a target that a switch recorded from another folder with a relative config path', async () => {
  const ctx = await setupTest();

  await ctx.createClone(['agent-1111111']);

  const home = join(ctx.directory, 'home');
  const elsewhere = join(ctx.directory, 'elsewhere');

  await mkdir(elsewhere);

  await writeFile(
    join(elsewhere, 'custom.json'),
    JSON.stringify({ targets: { cloud: { image: 'agent-1111111' } } }),
  );

  const imp = buildStubImp({
    images: Array.from({ length: 4 }, (_unused, index) => ({
      name: `agent-${String(index + 1).repeat(7)}`,
      digest: `imp-build-${index + 1}`,
      isPinned: true,
      createdAt: `2026-11-0${index + 1}T00:00:00Z`,
    })),
  });

  const stub = buildStubRunner(
    buildRealProgramHandler(['git', 'tar'], ctx.repo.env),
    imp.handler,
    buildStubCheckAgentImage(0),
  );

  await switchAgentImage({
    args: ['agent-1111111', 'custom.json'],
    home,
    cwd: elsewhere,
    now: createFakeClock({ startMs: Date.parse('2026-11-10T00:00:00Z') }).now,
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  await createAgentImage({
    args: [],
    cwd: ctx.clone,
    home,
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
    registerCleanup: () => () => {},
  });

  expect(
    stub.calls.filter((call) => call.argv[2] === 'unpin').map((call) => call.argv[3]),
  ).toStrictEqual(['agent-2222222', 'agent-3333333']);

  expect(imp.images.find((image) => image.name === 'agent-1111111')?.isPinned).toBe(true);
});
