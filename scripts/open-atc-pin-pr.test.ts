// each test commits its own pins to a real origin and asserts every output on its own, so its body
// is long
/* oxlint-disable max-lines-per-function, max-statements */
import { expect, onTestFinished, test } from 'bun:test';
import { copyFile, mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { openATCPinPR } from './open-atc-pin-pr.ts';
import { runProcess } from './run-process.ts';
import { buildRealProgramHandler } from './test-utils/build-real-program-handler.ts';
import { buildStubPinPRGh } from './test-utils/build-stub-pin-pr-gh.ts';
import { buildStubRunner } from './test-utils/build-stub-runner.ts';
import { createGitOrigin } from './test-utils/create-git-origin.ts';

// A real origin and seed, and recorders for the output. The seed holds the real pin-agent-atc.sh,
// because the script under test runs it from its checkout.
async function setupTest() {
  const dir = await mkdtemp(join(tmpdir(), 'open-atc-pin-pr-'));

  onTestFinished(() => rm(dir, { recursive: true, force: true }));

  const repo = await createGitOrigin(dir);

  await mkdir(join(repo.seed, 'scripts'));
  await mkdir(join(repo.seed, 'images/agent'), { recursive: true });

  await copyFile(
    join(import.meta.dir, 'pin-agent-atc.sh'),
    join(repo.seed, 'scripts/pin-agent-atc.sh'),
  );

  const out: string[] = [];
  const err: string[] = [];

  return {
    dir,
    repo,
    clone: join(dir, 'clone'),
    sums: join(dir, 'SHA256SUMS'),
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

test('it opens a pin pull request when none is open, from a branch it pushes', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.repo.seed, 'images/agent/Dockerfile'),
    'ARG ATC_VERSION=3.10.2\nARG ATC_SHA256=8f47233eab37dbfc0b700f2665a6caf69cbc986a73651d2b6f8f26eb908818c4\n',
  );

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the image']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'main']);
  await ctx.repo.git(['clone', '-q', ctx.repo.origin, ctx.clone]);

  await writeFile(
    ctx.sums,
    '4444444444444444444444444444444444444444444444444444444444444444  atc-linux-x64\n',
  );

  const stub = buildStubRunner(
    buildRealProgramHandler(['git', 'bash'], ctx.repo.env),
    buildStubPinPRGh({ openPRs: [] }),
  );

  const exitCode = await openATCPinPR({
    args: ['3.11.0', ctx.sums],
    cwd: ctx.clone,
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  const pinned = await ctx.repo.git([
    '--git-dir',
    ctx.repo.origin,
    'show',
    'atc-pin/agent-image:images/agent/Dockerfile',
  ]);

  const subjects = await ctx.repo.git([
    '--git-dir',
    ctx.repo.origin,
    'log',
    '--format=%s',
    'main..atc-pin/agent-image',
  ]);

  expect(exitCode).toBe(0);

  expect(ctx.out.join('')).toBe(
    'pinned atc 3.11.0: 4444444444444444444444444444444444444444444444444444444444444444\n' +
      'https://github.com/zgeoff/cloud/pull/200\n',
  );

  expect(ctx.err).toStrictEqual([]);

  expect(pinned).toBe(
    'ARG ATC_VERSION=3.11.0\nARG ATC_SHA256=4444444444444444444444444444444444444444444444444444444444444444',
  );

  expect(subjects).toBe('chore: pin atc 3.11.0 in the agent image');

  expect(stub.calls.filter((call) => call.argv[0] === 'gh').map((call) => call.argv)).toStrictEqual(
    [
      [
        'gh',
        'pr',
        'list',
        '--repo',
        'zgeoff/cloud',
        '--head',
        'atc-pin/agent-image',
        '--state',
        'open',
        '--json',
        'number,url,autoMergeRequest',
      ],
      [
        'gh',
        'pr',
        'create',
        '--repo',
        'zgeoff/cloud',
        '--base',
        'main',
        '--head',
        'atc-pin/agent-image',
        '--title',
        'chore: pin atc 3.11.0 in the agent image',
        '--body',
        "Pins atc 3.11.0 in the agent image, with the atc-linux-x64 sum from the release's SHA256SUMS. The agent image workflow turns on auto-merge once the image builds and passes its check and the diff changes only the two atc pins. After the merge, build and check the image as docs/runbooks/agent-image.md describes.",
      ],
    ],
  );
});

test('it turns the open pull request’s auto-merge off, replaces its branch, then updates it', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.repo.seed, 'images/agent/Dockerfile'),
    'ARG ATC_VERSION=3.10.2\nARG ATC_SHA256=8f47233eab37dbfc0b700f2665a6caf69cbc986a73651d2b6f8f26eb908818c4\n',
  );

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the image']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'main']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'switch', '-qc', 'atc-pin/agent-image']);

  await writeFile(
    join(ctx.repo.seed, 'images/agent/Dockerfile'),
    'ARG ATC_VERSION=3.10.9\nARG ATC_SHA256=5555555555555555555555555555555555555555555555555555555555555555\n',
  );

  await ctx.repo.git([
    '-C',
    ctx.repo.seed,
    'commit',
    '-qam',
    'chore: pin atc 3.10.9 in the agent image',
  ]);

  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'atc-pin/agent-image']);
  await ctx.repo.git(['clone', '-q', ctx.repo.origin, ctx.clone]);

  await writeFile(
    ctx.sums,
    '4444444444444444444444444444444444444444444444444444444444444444  atc-linux-x64\n',
  );

  const stub = buildStubRunner(
    buildRealProgramHandler(['git', 'bash'], ctx.repo.env),
    buildStubPinPRGh({
      openPRs: [
        {
          autoMergeRequest: { mergeMethod: 'SQUASH' },
          number: 12,
          url: 'https://github.com/zgeoff/cloud/pull/12',
        },
      ],
    }),
  );

  const exitCode = await openATCPinPR({
    args: ['3.11.0', ctx.sums],
    cwd: ctx.clone,
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  const pinned = await ctx.repo.git([
    '--git-dir',
    ctx.repo.origin,
    'show',
    'atc-pin/agent-image:images/agent/Dockerfile',
  ]);

  const subjects = await ctx.repo.git([
    '--git-dir',
    ctx.repo.origin,
    'log',
    '--format=%s',
    'main..atc-pin/agent-image',
  ]);

  expect(exitCode).toBe(0);

  expect(ctx.out.join('')).toBe(
    'pinned atc 3.11.0: 4444444444444444444444444444444444444444444444444444444444444444\n' +
      'https://github.com/zgeoff/cloud/pull/12\n',
  );

  expect(ctx.err).toStrictEqual([]);

  expect(pinned).toBe(
    'ARG ATC_VERSION=3.11.0\nARG ATC_SHA256=4444444444444444444444444444444444444444444444444444444444444444',
  );

  expect(subjects).toBe('chore: pin atc 3.11.0 in the agent image');

  expect(
    stub.calls.filter((call) => call.argv[0] === 'gh').map((call) => call.argv.slice(0, 5)),
  ).toStrictEqual([
    ['gh', 'pr', 'list', '--repo', 'zgeoff/cloud'],
    ['gh', 'pr', 'merge', '12', '--repo'],
    ['gh', 'pr', 'edit', '12', '--repo'],
  ]);

  expect(stub.calls.find((call) => call.argv[2] === 'merge')?.argv).toStrictEqual([
    'gh',
    'pr',
    'merge',
    '12',
    '--repo',
    'zgeoff/cloud',
    '--disable-auto',
  ]);

  expect(stub.calls.find((call) => call.argv[2] === 'edit')?.argv.slice(4)).toStrictEqual([
    '--repo',
    'zgeoff/cloud',
    '--title',
    'chore: pin atc 3.11.0 in the agent image',
    '--body',
    "Pins atc 3.11.0 in the agent image, with the atc-linux-x64 sum from the release's SHA256SUMS. The agent image workflow turns on auto-merge once the image builds and passes its check and the diff changes only the two atc pins. After the merge, build and check the image as docs/runbooks/agent-image.md describes.",
  ]);
});

test('it updates an open pull request without auto-merge directly', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.repo.seed, 'images/agent/Dockerfile'),
    'ARG ATC_VERSION=3.10.2\nARG ATC_SHA256=8f47233eab37dbfc0b700f2665a6caf69cbc986a73651d2b6f8f26eb908818c4\n',
  );

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the image']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'main']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'switch', '-qc', 'atc-pin/agent-image']);

  await writeFile(
    join(ctx.repo.seed, 'images/agent/Dockerfile'),
    'ARG ATC_VERSION=3.10.9\nARG ATC_SHA256=5555555555555555555555555555555555555555555555555555555555555555\n',
  );

  await ctx.repo.git([
    '-C',
    ctx.repo.seed,
    'commit',
    '-qam',
    'chore: pin atc 3.10.9 in the agent image',
  ]);

  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'atc-pin/agent-image']);
  await ctx.repo.git(['clone', '-q', ctx.repo.origin, ctx.clone]);

  await writeFile(
    ctx.sums,
    '4444444444444444444444444444444444444444444444444444444444444444  atc-linux-x64\n',
  );

  const stub = buildStubRunner(
    buildRealProgramHandler(['git', 'bash'], ctx.repo.env),
    buildStubPinPRGh({
      openPRs: [
        { autoMergeRequest: null, number: 12, url: 'https://github.com/zgeoff/cloud/pull/12' },
      ],
    }),
  );

  const exitCode = await openATCPinPR({
    args: ['3.11.0', ctx.sums],
    cwd: ctx.clone,
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(0);

  expect(ctx.out.join('')).toBe(
    'pinned atc 3.11.0: 4444444444444444444444444444444444444444444444444444444444444444\n' +
      'https://github.com/zgeoff/cloud/pull/12\n',
  );

  expect(
    stub.calls.filter((call) => call.argv[0] === 'gh').map((call) => call.argv.slice(0, 4)),
  ).toStrictEqual([
    ['gh', 'pr', 'list', '--repo'],
    ['gh', 'pr', 'edit', '12'],
  ]);
});

test('it stops without a push or a gh call when main already pins the release', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.repo.seed, 'images/agent/Dockerfile'),
    'ARG ATC_VERSION=3.11.0\nARG ATC_SHA256=4444444444444444444444444444444444444444444444444444444444444444\n',
  );

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the image']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'main']);
  await ctx.repo.git(['clone', '-q', ctx.repo.origin, ctx.clone]);

  await writeFile(
    ctx.sums,
    '4444444444444444444444444444444444444444444444444444444444444444  atc-linux-x64\n',
  );

  const stub = buildStubRunner(
    buildRealProgramHandler(['git', 'bash'], ctx.repo.env),
    buildStubPinPRGh({ openPRs: [] }),
  );

  const exitCode = await openATCPinPR({
    args: ['3.11.0', ctx.sums],
    cwd: ctx.clone,
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  const refs = await ctx.repo.git([
    '--git-dir',
    ctx.repo.origin,
    'for-each-ref',
    '--format=%(refname)',
  ]);

  expect(exitCode).toBe(0);
  expect(ctx.out.join('')).toBe('atc 3.11.0 is already pinned\n');
  expect(refs).toBe('refs/heads/main');
  expect(stub.calls.filter((call) => call.argv[0] === 'gh')).toStrictEqual([]);
});

test('it stops without a push or a gh call when the branch already holds a newer release', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.repo.seed, 'images/agent/Dockerfile'),
    'ARG ATC_VERSION=3.10.2\nARG ATC_SHA256=8f47233eab37dbfc0b700f2665a6caf69cbc986a73651d2b6f8f26eb908818c4\n',
  );

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the image']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'main']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'switch', '-qc', 'atc-pin/agent-image']);

  await writeFile(
    join(ctx.repo.seed, 'images/agent/Dockerfile'),
    'ARG ATC_VERSION=3.12.0\nARG ATC_SHA256=6666666666666666666666666666666666666666666666666666666666666666\n',
  );

  await ctx.repo.git([
    '-C',
    ctx.repo.seed,
    'commit',
    '-qam',
    'chore: pin atc 3.12.0 in the agent image',
  ]);

  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'atc-pin/agent-image']);
  await ctx.repo.git(['clone', '-q', ctx.repo.origin, ctx.clone]);

  await writeFile(
    ctx.sums,
    '4444444444444444444444444444444444444444444444444444444444444444  atc-linux-x64\n',
  );

  const before = await ctx.repo.git([
    '--git-dir',
    ctx.repo.origin,
    'rev-parse',
    'atc-pin/agent-image',
  ]);

  const stub = buildStubRunner(
    buildRealProgramHandler(['git', 'bash'], ctx.repo.env),
    buildStubPinPRGh({ openPRs: [] }),
  );

  const exitCode = await openATCPinPR({
    args: ['3.11.0', ctx.sums],
    cwd: ctx.clone,
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  const after = await ctx.repo.git([
    '--git-dir',
    ctx.repo.origin,
    'rev-parse',
    'atc-pin/agent-image',
  ]);

  expect(exitCode).toBe(0);

  expect(ctx.out.join('')).toBe(
    'pinned atc 3.11.0: 4444444444444444444444444444444444444444444444444444444444444444\n' +
      'atc-pin/agent-image already pins atc 3.12.0, which is newer than 3.11.0\n',
  );

  expect(after).toBe(before);
  expect(stub.calls.filter((call) => call.argv[0] === 'gh')).toStrictEqual([]);
});

test('it compares releases by version, not as text', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.repo.seed, 'images/agent/Dockerfile'),
    'ARG ATC_VERSION=3.9.0\nARG ATC_SHA256=8f47233eab37dbfc0b700f2665a6caf69cbc986a73651d2b6f8f26eb908818c4\n',
  );

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the image']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'main']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'switch', '-qc', 'atc-pin/agent-image']);

  await writeFile(
    join(ctx.repo.seed, 'images/agent/Dockerfile'),
    'ARG ATC_VERSION=3.9.1\nARG ATC_SHA256=5555555555555555555555555555555555555555555555555555555555555555\n',
  );

  await ctx.repo.git([
    '-C',
    ctx.repo.seed,
    'commit',
    '-qam',
    'chore: pin atc 3.9.1 in the agent image',
  ]);

  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'atc-pin/agent-image']);
  await ctx.repo.git(['clone', '-q', ctx.repo.origin, ctx.clone]);

  await writeFile(
    ctx.sums,
    '4444444444444444444444444444444444444444444444444444444444444444  atc-linux-x64\n',
  );

  const stub = buildStubRunner(
    buildRealProgramHandler(['git', 'bash'], ctx.repo.env),
    buildStubPinPRGh({ openPRs: [] }),
  );

  const exitCode = await openATCPinPR({
    args: ['3.10.0', ctx.sums],
    cwd: ctx.clone,
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  const pinned = await ctx.repo.git([
    '--git-dir',
    ctx.repo.origin,
    'show',
    'atc-pin/agent-image:images/agent/Dockerfile',
  ]);

  expect(exitCode).toBe(0);
  expect(pinned).toStartWith('ARG ATC_VERSION=3.10.0\n');
});

test('it opens the missing pull request when the branch already holds the release, without a push', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.repo.seed, 'images/agent/Dockerfile'),
    'ARG ATC_VERSION=3.10.2\nARG ATC_SHA256=8f47233eab37dbfc0b700f2665a6caf69cbc986a73651d2b6f8f26eb908818c4\n',
  );

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the image']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'main']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'switch', '-qc', 'atc-pin/agent-image']);

  await writeFile(
    join(ctx.repo.seed, 'images/agent/Dockerfile'),
    'ARG ATC_VERSION=3.11.0\nARG ATC_SHA256=4444444444444444444444444444444444444444444444444444444444444444\n',
  );

  await ctx.repo.git([
    '-C',
    ctx.repo.seed,
    'commit',
    '-qam',
    'chore: pin atc 3.11.0 in the agent image',
  ]);

  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'atc-pin/agent-image']);
  await ctx.repo.git(['clone', '-q', ctx.repo.origin, ctx.clone]);

  await writeFile(
    ctx.sums,
    '4444444444444444444444444444444444444444444444444444444444444444  atc-linux-x64\n',
  );

  const before = await ctx.repo.git([
    '--git-dir',
    ctx.repo.origin,
    'rev-parse',
    'atc-pin/agent-image',
  ]);

  const stub = buildStubRunner(
    buildRealProgramHandler(['git', 'bash'], ctx.repo.env),
    buildStubPinPRGh({ openPRs: [] }),
  );

  const exitCode = await openATCPinPR({
    args: ['3.11.0', ctx.sums],
    cwd: ctx.clone,
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  const after = await ctx.repo.git([
    '--git-dir',
    ctx.repo.origin,
    'rev-parse',
    'atc-pin/agent-image',
  ]);

  expect(exitCode).toBe(0);

  expect(ctx.out.join('')).toBe(
    'pinned atc 3.11.0: 4444444444444444444444444444444444444444444444444444444444444444\n' +
      'https://github.com/zgeoff/cloud/pull/200\n',
  );

  expect(after).toBe(before);

  expect(
    stub.calls.filter((call) => call.argv[0] === 'gh').map((call) => call.argv.slice(0, 3)),
  ).toStrictEqual([
    ['gh', 'pr', 'list'],
    ['gh', 'pr', 'create'],
  ]);
});

test('it leaves an open pull request that already holds the release alone', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.repo.seed, 'images/agent/Dockerfile'),
    'ARG ATC_VERSION=3.10.2\nARG ATC_SHA256=8f47233eab37dbfc0b700f2665a6caf69cbc986a73651d2b6f8f26eb908818c4\n',
  );

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the image']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'main']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'switch', '-qc', 'atc-pin/agent-image']);

  await writeFile(
    join(ctx.repo.seed, 'images/agent/Dockerfile'),
    'ARG ATC_VERSION=3.11.0\nARG ATC_SHA256=4444444444444444444444444444444444444444444444444444444444444444\n',
  );

  await ctx.repo.git([
    '-C',
    ctx.repo.seed,
    'commit',
    '-qam',
    'chore: pin atc 3.11.0 in the agent image',
  ]);

  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'atc-pin/agent-image']);
  await ctx.repo.git(['clone', '-q', ctx.repo.origin, ctx.clone]);

  await writeFile(
    ctx.sums,
    '4444444444444444444444444444444444444444444444444444444444444444  atc-linux-x64\n',
  );

  const stub = buildStubRunner(
    buildRealProgramHandler(['git', 'bash'], ctx.repo.env),
    buildStubPinPRGh({
      openPRs: [
        {
          autoMergeRequest: { mergeMethod: 'SQUASH' },
          number: 12,
          url: 'https://github.com/zgeoff/cloud/pull/12',
        },
      ],
    }),
  );

  const exitCode = await openATCPinPR({
    args: ['3.11.0', ctx.sums],
    cwd: ctx.clone,
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(0);

  expect(ctx.out.join('')).toBe(
    'pinned atc 3.11.0: 4444444444444444444444444444444444444444444444444444444444444444\n' +
      'https://github.com/zgeoff/cloud/pull/12 already pins atc 3.11.0\n',
  );

  expect(
    stub.calls.filter((call) => call.argv[0] === 'gh').map((call) => call.argv.slice(0, 3)),
  ).toStrictEqual([['gh', 'pr', 'list']]);
});

test('it fails with the pin’s exit code and message, without a push or a gh call', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.repo.seed, 'images/agent/Dockerfile'),
    'ARG ATC_VERSION=3.10.2\nARG ATC_SHA256=8f47233eab37dbfc0b700f2665a6caf69cbc986a73651d2b6f8f26eb908818c4\n',
  );

  await ctx.repo.git(['-C', ctx.repo.seed, 'add', '-A']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'commit', '-qm', 'add the image']);
  await ctx.repo.git(['-C', ctx.repo.seed, 'push', '-q', 'origin', 'main']);
  await ctx.repo.git(['clone', '-q', ctx.repo.origin, ctx.clone]);

  await writeFile(
    ctx.sums,
    '4444444444444444444444444444444444444444444444444444444444444444  atc-darwin-arm64\n',
  );

  const stub = buildStubRunner(
    buildRealProgramHandler(['git', 'bash'], ctx.repo.env),
    buildStubPinPRGh({ openPRs: [] }),
  );

  const exitCode = await openATCPinPR({
    args: ['3.11.0', ctx.sums],
    cwd: ctx.clone,
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  const refs = await ctx.repo.git([
    '--git-dir',
    ctx.repo.origin,
    'for-each-ref',
    '--format=%(refname)',
  ]);

  expect(exitCode).toBe(1);
  expect(ctx.err).toStrictEqual(['SHA256SUMS has 0 atc-linux-x64 lines, want 1\n']);
  expect(refs).toBe('refs/heads/main');
  expect(stub.calls.filter((call) => call.argv[0] === 'gh')).toStrictEqual([]);
});

test.each([
  ['no arguments', []],
  ['a version without a SHA256SUMS file', ['3.11.0']],
  ['an extra argument', ['3.11.0', 'SHA256SUMS', 'more']],
])('it prints its usage and exits 2 for %s', async (_label, args) => {
  const ctx = await setupTest();

  const stub = buildStubRunner();

  const exitCode = await openATCPinPR({
    args,
    cwd: ctx.dir,
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(2);
  expect(ctx.err).toStrictEqual(['usage: open-atc-pin-pr.sh <version> <SHA256SUMS file>\n']);
  expect(stub.calls).toStrictEqual([]);
});

test('it runs through the bash entry point that atc’s release job calls', async () => {
  const ctx = await setupTest();

  const result = await runProcess(['bash', join(import.meta.dir, 'open-atc-pin-pr.sh'), '3.11.0'], {
    cwd: ctx.dir,
    env: { PATH: process.env['PATH'] ?? '/usr/bin:/bin', HOME: ctx.dir },
  });

  expect(result).toStrictEqual({
    exitCode: 2,
    stdout: Buffer.from(''),
    stderr: Buffer.from('usage: open-atc-pin-pr.sh <version> <SHA256SUMS file>\n'),
    timedOut: false,
  });
});
