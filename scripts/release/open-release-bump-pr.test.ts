// a pin callback reports success as undefined, as the PR opener's applyPins type says
/* oxlint-disable unicorn/no-useless-undefined */
import { expect, mock, onTestFinished, test } from 'bun:test';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildRealProgramHandler } from '../test-utils/build-real-program-handler.ts';
import { buildStubReleaseGH } from '../test-utils/build-stub-release-gh.ts';
import { buildStubRunner } from '../test-utils/build-stub-runner.ts';
import { createGitOrigin } from '../test-utils/create-git-origin.ts';
import { openReleaseBumpPR } from './open-release-bump-pr.ts';

async function setupTest() {
  const dir = await mkdtemp(join(tmpdir(), 'open-release-bump-pr-'));

  onTestFinished(() => rm(dir, { recursive: true, force: true }));

  const origin = await createGitOrigin(dir);

  const printOut = mock<(text: string) => void>();
  const printErr = mock<(text: string) => void>();

  return { origin, clone: join(dir, 'clone'), printOut, printErr };
}

test('it opens a labelled pull request when none is open', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.origin.seed, 'pins'), 'nixie 0.7.0\n');

  await ctx.origin.git(['-C', ctx.origin.seed, 'add', '-A']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'commit', '-qm', 'add the pins']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'push', '-q', 'origin', 'main']);
  await ctx.origin.git(['clone', '-q', ctx.origin.origin, ctx.clone]);

  const stub = buildStubRunner(
    buildStubReleaseGH({}),
    buildRealProgramHandler(['git'], ctx.origin.env),
  );

  const status = await openReleaseBumpPR(
    {
      cwd: ctx.clone,
      env: ctx.origin.env,
      run: stub.run,
      printOut: ctx.printOut,
      printErr: ctx.printErr,
    },
    {
      dependency: 'nixie',
      version: '0.7.1',
      body: 'Bumps nixie to 0.7.1.\n',
      labels: ['update:patch', 'auto-merge'],
      applyPins: async () => {
        await writeFile(join(ctx.clone, 'pins'), 'nixie 0.7.1\n');

        return undefined;
      },
    },
  );

  const pins = await ctx.origin.git([
    '--git-dir',
    ctx.origin.origin,
    'show',
    'release-check/nixie:pins',
  ]);

  const log = await ctx.origin.git([
    '--git-dir',
    ctx.origin.origin,
    'log',
    '--format=%s',
    'main..release-check/nixie',
  ]);

  expect(status).toBe(0);
  expect(ctx.printOut.mock.calls).toStrictEqual([['https://github.com/zgeoff/cloud/pull/200\n']]);
  expect(ctx.printErr).not.toHaveBeenCalled();
  expect(pins).toBe('nixie 0.7.1');
  expect(log).toBe('chore(nixie): bump nixie to 0.7.1');

  expect(
    stub.calls.filter((call) => call.argv[0] === 'gh').map((call) => [call.argv, call.stdin]),
  ).toStrictEqual([
    [
      [
        'gh',
        'pr',
        'list',
        '--repo',
        'zgeoff/cloud',
        '--head',
        'release-check/nixie',
        '--state',
        'open',
        '--json',
        'number,url,autoMergeRequest,labels,headRefOid,isCrossRepository',
      ],
      '',
    ],
    [
      [
        'gh',
        'label',
        'create',
        'update:patch',
        '--repo',
        'zgeoff/cloud',
        '--force',
        '--color',
        '0e8a16',
        '--description',
        'a patch release',
      ],
      '',
    ],
    [
      [
        'gh',
        'label',
        'create',
        'auto-merge',
        '--repo',
        'zgeoff/cloud',
        '--force',
        '--color',
        '0e8a16',
        '--description',
        'merges on its own once its checks pass',
      ],
      '',
    ],
    [
      [
        'gh',
        'pr',
        'create',
        '--repo',
        'zgeoff/cloud',
        '--base',
        'main',
        '--head',
        'release-check/nixie',
        '--title',
        'chore(nixie): bump nixie to 0.7.1',
        '--body-file',
        '-',
        '--label',
        'update:patch,auto-merge',
      ],
      'Bumps nixie to 0.7.1.\n',
    ],
  ]);
});

test('it updates the open pull request and its labels after it turns auto-merge off', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.origin.seed, 'pins'), 'atc 4.2.0\n');

  await ctx.origin.git(['-C', ctx.origin.seed, 'add', '-A']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'commit', '-qm', 'add the pins']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'push', '-q', 'origin', 'main']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'switch', '-qc', 'release-check/atc']);

  await writeFile(join(ctx.origin.seed, 'pins'), 'atc 4.2.1\n');

  await ctx.origin.git(['-C', ctx.origin.seed, 'commit', '-qam', 'chore(atc): bump atc to 4.2.1']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'push', '-q', 'origin', 'release-check/atc']);
  await ctx.origin.git(['clone', '-q', ctx.origin.origin, ctx.clone]);

  const stub = buildStubRunner(
    buildStubReleaseGH({
      openPRs: [
        {
          autoMergeRequest: { mergeMethod: 'SQUASH' },
          isCrossRepository: false,
          labels: [{ name: 'auto-merge' }, { name: 'keep me' }, { name: 'update:patch' }],
          number: 12,
          url: 'https://github.com/zgeoff/cloud/pull/12',
        },
      ],
    }),
    buildRealProgramHandler(['git'], ctx.origin.env),
  );

  const status = await openReleaseBumpPR(
    {
      cwd: ctx.clone,
      env: ctx.origin.env,
      run: stub.run,
      printOut: ctx.printOut,
      printErr: ctx.printErr,
    },
    {
      dependency: 'atc',
      version: '5.0.0',
      body: 'Bumps atc to 5.0.0.\n',
      labels: ['update:major', 'needs-review'],
      applyPins: async () => {
        await writeFile(join(ctx.clone, 'pins'), 'atc 5.0.0\n');

        return undefined;
      },
    },
  );

  const pins = await ctx.origin.git([
    '--git-dir',
    ctx.origin.origin,
    'show',
    'release-check/atc:pins',
  ]);

  const log = await ctx.origin.git([
    '--git-dir',
    ctx.origin.origin,
    'log',
    '--format=%s',
    'main..release-check/atc',
  ]);

  expect(status).toBe(0);
  expect(ctx.printOut.mock.calls).toStrictEqual([['https://github.com/zgeoff/cloud/pull/12\n']]);
  expect(ctx.printErr).not.toHaveBeenCalled();
  expect(pins).toBe('atc 5.0.0');
  expect(log).toBe('chore(atc): bump atc to 5.0.0');

  expect(
    stub.calls.filter((call) => call.argv[0] === 'gh').map((call) => [call.argv, call.stdin]),
  ).toStrictEqual([
    [
      [
        'gh',
        'pr',
        'list',
        '--repo',
        'zgeoff/cloud',
        '--head',
        'release-check/atc',
        '--state',
        'open',
        '--json',
        'number,url,autoMergeRequest,labels,headRefOid,isCrossRepository',
      ],
      '',
    ],
    [
      [
        'gh',
        'label',
        'create',
        'update:major',
        '--repo',
        'zgeoff/cloud',
        '--force',
        '--color',
        'd73a4a',
        '--description',
        'a major release',
      ],
      '',
    ],
    [
      [
        'gh',
        'label',
        'create',
        'needs-review',
        '--repo',
        'zgeoff/cloud',
        '--force',
        '--color',
        'd73a4a',
        '--description',
        'waits for a review before it merges',
      ],
      '',
    ],
    [['gh', 'pr', 'merge', '12', '--repo', 'zgeoff/cloud', '--disable-auto'], ''],
    [['gh', 'pr', 'edit', '12', '--repo', 'zgeoff/cloud', '--remove-label', 'auto-merge'], ''],
    [
      [
        'gh',
        'pr',
        'edit',
        '12',
        '--repo',
        'zgeoff/cloud',
        '--add-label',
        'needs-review,update:major',
        '--remove-label',
        'update:patch',
      ],
      '',
    ],
    [
      [
        'gh',
        'pr',
        'edit',
        '12',
        '--repo',
        'zgeoff/cloud',
        '--title',
        'chore(atc): bump atc to 5.0.0',
        '--body-file',
        '-',
      ],
      'Bumps atc to 5.0.0.\n',
    ],
  ]);
});

test('it opens the missing pull request when the branch already holds the change', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.origin.seed, 'pins'), 'imp 1.0.0\n');

  await ctx.origin.git(['-C', ctx.origin.seed, 'add', '-A']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'commit', '-qm', 'add the pins']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'push', '-q', 'origin', 'main']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'switch', '-qc', 'release-check/imp']);

  await writeFile(join(ctx.origin.seed, 'pins'), 'imp 1.0.1\n');

  await ctx.origin.git(['-C', ctx.origin.seed, 'commit', '-qam', 'chore(imp): bump imp to 1.0.1']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'push', '-q', 'origin', 'release-check/imp']);
  await ctx.origin.git(['clone', '-q', ctx.origin.origin, ctx.clone]);

  const before = await ctx.origin.git([
    '--git-dir',
    ctx.origin.origin,
    'rev-parse',
    'release-check/imp',
  ]);

  const stub = buildStubRunner(
    buildStubReleaseGH({}),
    buildRealProgramHandler(['git'], ctx.origin.env),
  );

  const status = await openReleaseBumpPR(
    {
      cwd: ctx.clone,
      env: ctx.origin.env,
      run: stub.run,
      printOut: ctx.printOut,
      printErr: ctx.printErr,
    },
    {
      dependency: 'imp',
      version: '1.0.1',
      body: 'Bumps imp to 1.0.1.\n',
      labels: ['update:patch', 'auto-merge'],
      applyPins: async () => {
        await writeFile(join(ctx.clone, 'pins'), 'imp 1.0.1\n');

        return undefined;
      },
    },
  );

  const after = await ctx.origin.git([
    '--git-dir',
    ctx.origin.origin,
    'rev-parse',
    'release-check/imp',
  ]);

  expect(status).toBe(0);
  expect(ctx.printOut.mock.calls).toStrictEqual([['https://github.com/zgeoff/cloud/pull/200\n']]);
  expect(ctx.printErr).not.toHaveBeenCalled();
  expect(after).toBe(before);

  expect(stub.calls.filter((call) => call.argv[0] === 'gh').map((call) => call.argv)).toStrictEqual(
    [
      [
        'gh',
        'pr',
        'list',
        '--repo',
        'zgeoff/cloud',
        '--head',
        'release-check/imp',
        '--state',
        'open',
        '--json',
        'number,url,autoMergeRequest,labels,headRefOid,isCrossRepository',
      ],
      [
        'gh',
        'label',
        'create',
        'update:patch',
        '--repo',
        'zgeoff/cloud',
        '--force',
        '--color',
        '0e8a16',
        '--description',
        'a patch release',
      ],
      [
        'gh',
        'label',
        'create',
        'auto-merge',
        '--repo',
        'zgeoff/cloud',
        '--force',
        '--color',
        '0e8a16',
        '--description',
        'merges on its own once its checks pass',
      ],
      [
        'gh',
        'pr',
        'list',
        '--repo',
        'zgeoff/cloud',
        '--head',
        'release-check/imp',
        '--state',
        'closed',
        '--json',
        'number,url,autoMergeRequest,labels,headRefOid,isCrossRepository',
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
        'release-check/imp',
        '--title',
        'chore(imp): bump imp to 1.0.1',
        '--body-file',
        '-',
        '--label',
        'update:patch,auto-merge',
      ],
    ],
  );
});

test('it pushes nothing when main moved only in other files', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.origin.seed, 'pins'), 'imp 1.0.0\n');

  await ctx.origin.git(['-C', ctx.origin.seed, 'add', '-A']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'commit', '-qm', 'add the pins']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'push', '-q', 'origin', 'main']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'switch', '-qc', 'release-check/imp']);

  await writeFile(join(ctx.origin.seed, 'pins'), 'imp 1.0.1\n');

  await ctx.origin.git(['-C', ctx.origin.seed, 'commit', '-qam', 'chore(imp): bump imp to 1.0.1']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'push', '-q', 'origin', 'release-check/imp']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'switch', '-q', 'main']);

  await writeFile(join(ctx.origin.seed, 'notes'), 'other work\n');

  await ctx.origin.git(['-C', ctx.origin.seed, 'add', 'notes']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'commit', '-qm', 'add notes']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'push', '-q', 'origin', 'main']);
  await ctx.origin.git(['clone', '-q', ctx.origin.origin, ctx.clone]);

  const before = await ctx.origin.git([
    '--git-dir',
    ctx.origin.origin,
    'rev-parse',
    'release-check/imp',
  ]);

  const stub = buildStubRunner(
    buildStubReleaseGH({
      openPRs: [
        {
          autoMergeRequest: null,
          isCrossRepository: false,
          labels: [{ name: 'auto-merge' }, { name: 'update:patch' }],
          number: 14,
          url: 'https://github.com/zgeoff/cloud/pull/14',
        },
      ],
    }),
    buildRealProgramHandler(['git'], ctx.origin.env),
  );

  const status = await openReleaseBumpPR(
    {
      cwd: ctx.clone,
      env: ctx.origin.env,
      run: stub.run,
      printOut: ctx.printOut,
      printErr: ctx.printErr,
    },
    {
      dependency: 'imp',
      version: '1.0.1',
      body: 'Bumps imp to 1.0.1.\n',
      labels: ['update:patch', 'auto-merge'],
      applyPins: async () => {
        await writeFile(join(ctx.clone, 'pins'), 'imp 1.0.1\n');

        return undefined;
      },
    },
  );

  const after = await ctx.origin.git([
    '--git-dir',
    ctx.origin.origin,
    'rev-parse',
    'release-check/imp',
  ]);

  expect(status).toBe(0);

  expect(ctx.printOut.mock.calls).toStrictEqual([
    ['https://github.com/zgeoff/cloud/pull/14 already bumps imp to 1.0.1\n'],
  ]);

  expect(ctx.printErr).not.toHaveBeenCalled();
  expect(after).toBe(before);

  expect(stub.calls.filter((call) => call.argv[0] === 'gh').map((call) => call.argv)).toStrictEqual(
    [
      [
        'gh',
        'pr',
        'list',
        '--repo',
        'zgeoff/cloud',
        '--head',
        'release-check/imp',
        '--state',
        'open',
        '--json',
        'number,url,autoMergeRequest,labels,headRefOid,isCrossRepository',
      ],
      [
        'gh',
        'label',
        'create',
        'update:patch',
        '--repo',
        'zgeoff/cloud',
        '--force',
        '--color',
        '0e8a16',
        '--description',
        'a patch release',
      ],
      [
        'gh',
        'label',
        'create',
        'auto-merge',
        '--repo',
        'zgeoff/cloud',
        '--force',
        '--color',
        '0e8a16',
        '--description',
        'merges on its own once its checks pass',
      ],
    ],
  );
});

test('it puts back the auto-merge label with no push after a run that failed past its push', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.origin.seed, 'pins'), 'imp 1.0.0\n');

  await ctx.origin.git(['-C', ctx.origin.seed, 'add', '-A']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'commit', '-qm', 'add the pins']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'push', '-q', 'origin', 'main']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'switch', '-qc', 'release-check/imp']);

  await writeFile(join(ctx.origin.seed, 'pins'), 'imp 1.0.1\n');

  await ctx.origin.git(['-C', ctx.origin.seed, 'commit', '-qam', 'chore(imp): bump imp to 1.0.1']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'push', '-q', 'origin', 'release-check/imp']);
  await ctx.origin.git(['clone', '-q', ctx.origin.origin, ctx.clone]);

  const before = await ctx.origin.git([
    '--git-dir',
    ctx.origin.origin,
    'rev-parse',
    'release-check/imp',
  ]);

  // the run before pushed this head, took auto-merge off and failed before it put it back
  const stub = buildStubRunner(
    buildStubReleaseGH({
      openPRs: [
        {
          autoMergeRequest: null,
          isCrossRepository: false,
          labels: [{ name: 'update:patch' }],
          number: 14,
          url: 'https://github.com/zgeoff/cloud/pull/14',
        },
      ],
    }),
    buildRealProgramHandler(['git'], ctx.origin.env),
  );

  const status = await openReleaseBumpPR(
    {
      cwd: ctx.clone,
      env: ctx.origin.env,
      run: stub.run,
      printOut: ctx.printOut,
      printErr: ctx.printErr,
    },
    {
      dependency: 'imp',
      version: '1.0.1',
      body: 'Bumps imp to 1.0.1.\n',
      labels: ['update:patch', 'auto-merge'],
      applyPins: async () => {
        await writeFile(join(ctx.clone, 'pins'), 'imp 1.0.1\n');

        return undefined;
      },
    },
  );

  const after = await ctx.origin.git([
    '--git-dir',
    ctx.origin.origin,
    'rev-parse',
    'release-check/imp',
  ]);

  expect(status).toBe(0);

  expect(ctx.printOut.mock.calls).toStrictEqual([
    ['https://github.com/zgeoff/cloud/pull/14 already bumps imp to 1.0.1\n'],
  ]);

  expect(ctx.printErr).not.toHaveBeenCalled();
  expect(after).toBe(before);

  expect(stub.calls.filter((call) => call.argv[0] === 'gh').map((call) => call.argv)).toStrictEqual(
    [
      [
        'gh',
        'pr',
        'list',
        '--repo',
        'zgeoff/cloud',
        '--head',
        'release-check/imp',
        '--state',
        'open',
        '--json',
        'number,url,autoMergeRequest,labels,headRefOid,isCrossRepository',
      ],
      [
        'gh',
        'label',
        'create',
        'update:patch',
        '--repo',
        'zgeoff/cloud',
        '--force',
        '--color',
        '0e8a16',
        '--description',
        'a patch release',
      ],
      [
        'gh',
        'label',
        'create',
        'auto-merge',
        '--repo',
        'zgeoff/cloud',
        '--force',
        '--color',
        '0e8a16',
        '--description',
        'merges on its own once its checks pass',
      ],
      ['gh', 'pr', 'edit', '14', '--repo', 'zgeoff/cloud', '--add-label', 'auto-merge'],
    ],
  );
});

test('it rebuilds the branch when main changed a pinned file', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.origin.seed, 'pins'), '# pins\nimp 1.0.0\n');

  await ctx.origin.git(['-C', ctx.origin.seed, 'add', '-A']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'commit', '-qm', 'add the pins']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'push', '-q', 'origin', 'main']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'switch', '-qc', 'release-check/imp']);

  await writeFile(join(ctx.origin.seed, 'pins'), '# pins\nimp 1.0.1\n');

  await ctx.origin.git(['-C', ctx.origin.seed, 'commit', '-qam', 'chore(imp): bump imp to 1.0.1']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'push', '-q', 'origin', 'release-check/imp']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'switch', '-q', 'main']);

  await writeFile(join(ctx.origin.seed, 'pins'), '# the pins, by release\nimp 1.0.0\n');

  await ctx.origin.git(['-C', ctx.origin.seed, 'commit', '-qam', 'describe the pins']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'push', '-q', 'origin', 'main']);
  await ctx.origin.git(['clone', '-q', ctx.origin.origin, ctx.clone]);

  const stub = buildStubRunner(
    buildStubReleaseGH({
      openPRs: [
        {
          autoMergeRequest: null,
          isCrossRepository: false,
          labels: [{ name: 'auto-merge' }, { name: 'update:patch' }],
          number: 14,
          url: 'https://github.com/zgeoff/cloud/pull/14',
        },
      ],
    }),
    buildRealProgramHandler(['git'], ctx.origin.env),
  );

  const status = await openReleaseBumpPR(
    {
      cwd: ctx.clone,
      env: ctx.origin.env,
      run: stub.run,
      printOut: ctx.printOut,
      printErr: ctx.printErr,
    },
    {
      dependency: 'imp',
      version: '1.0.1',
      body: 'Bumps imp to 1.0.1.\n',
      labels: ['update:patch', 'auto-merge'],
      applyPins: async () => {
        const pins = await readFile(join(ctx.clone, 'pins'), 'utf8');

        await writeFile(join(ctx.clone, 'pins'), pins.replace(/^imp .*$/mu, 'imp 1.0.1'));

        return undefined;
      },
    },
  );

  const pins = await ctx.origin.git([
    '--git-dir',
    ctx.origin.origin,
    'show',
    'release-check/imp:pins',
  ]);

  const log = await ctx.origin.git([
    '--git-dir',
    ctx.origin.origin,
    'log',
    '--format=%s',
    'main..release-check/imp',
  ]);

  expect(status).toBe(0);
  expect(ctx.printOut.mock.calls).toStrictEqual([['https://github.com/zgeoff/cloud/pull/14\n']]);
  expect(ctx.printErr).not.toHaveBeenCalled();
  expect(pins).toBe('# the pins, by release\nimp 1.0.1');
  expect(log).toBe('chore(imp): bump imp to 1.0.1');

  expect(stub.calls.filter((call) => call.argv[0] === 'gh').map((call) => call.argv)).toStrictEqual(
    [
      [
        'gh',
        'pr',
        'list',
        '--repo',
        'zgeoff/cloud',
        '--head',
        'release-check/imp',
        '--state',
        'open',
        '--json',
        'number,url,autoMergeRequest,labels,headRefOid,isCrossRepository',
      ],
      [
        'gh',
        'label',
        'create',
        'update:patch',
        '--repo',
        'zgeoff/cloud',
        '--force',
        '--color',
        '0e8a16',
        '--description',
        'a patch release',
      ],
      [
        'gh',
        'label',
        'create',
        'auto-merge',
        '--repo',
        'zgeoff/cloud',
        '--force',
        '--color',
        '0e8a16',
        '--description',
        'merges on its own once its checks pass',
      ],
      ['gh', 'pr', 'edit', '14', '--repo', 'zgeoff/cloud', '--remove-label', 'auto-merge'],
      ['gh', 'pr', 'edit', '14', '--repo', 'zgeoff/cloud', '--add-label', 'auto-merge'],
      [
        'gh',
        'pr',
        'edit',
        '14',
        '--repo',
        'zgeoff/cloud',
        '--title',
        'chore(imp): bump imp to 1.0.1',
        '--body-file',
        '-',
      ],
    ],
  );
});

test('it stops when main already pins the release', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.origin.seed, 'pins'), 'nixie 0.7.1\n');

  await ctx.origin.git(['-C', ctx.origin.seed, 'add', '-A']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'commit', '-qm', 'add the pins']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'push', '-q', 'origin', 'main']);
  await ctx.origin.git(['clone', '-q', ctx.origin.origin, ctx.clone]);

  const stub = buildStubRunner(
    buildStubReleaseGH({}),
    buildRealProgramHandler(['git'], ctx.origin.env),
  );

  const status = await openReleaseBumpPR(
    {
      cwd: ctx.clone,
      env: ctx.origin.env,
      run: stub.run,
      printOut: ctx.printOut,
      printErr: ctx.printErr,
    },
    {
      dependency: 'nixie',
      version: '0.7.1',
      body: 'Bumps nixie to 0.7.1.\n',
      labels: ['update:patch', 'auto-merge'],
      applyPins: async () => {
        ctx.printOut('nixie already pins 0.7.1\n');

        await writeFile(join(ctx.clone, 'pins'), 'nixie 0.7.1\n');

        return undefined;
      },
    },
  );

  const refs = await ctx.origin.git([
    '--git-dir',
    ctx.origin.origin,
    'for-each-ref',
    '--format=%(refname)',
  ]);

  expect(status).toBe(0);
  expect(ctx.printOut.mock.calls).toStrictEqual([['nixie already pins 0.7.1\n']]);
  expect(ctx.printErr).not.toHaveBeenCalled();
  expect(refs).toBe('refs/heads/main');
  expect(stub.calls.filter((call) => call.argv[0] === 'gh')).toStrictEqual([]);
});

test('it fails without a push when the pin fails', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.origin.seed, 'pins'), 'nixie 0.7.0\n');

  await ctx.origin.git(['-C', ctx.origin.seed, 'add', '-A']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'commit', '-qm', 'add the pins']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'push', '-q', 'origin', 'main']);
  await ctx.origin.git(['clone', '-q', ctx.origin.origin, ctx.clone]);

  const stub = buildStubRunner(
    buildStubReleaseGH({}),
    buildRealProgramHandler(['git'], ctx.origin.env),
  );

  const status = await openReleaseBumpPR(
    {
      cwd: ctx.clone,
      env: ctx.origin.env,
      run: stub.run,
      printOut: ctx.printOut,
      printErr: ctx.printErr,
    },
    {
      dependency: 'nixie',
      version: '0.7.1',
      body: 'Bumps nixie to 0.7.1.\n',
      labels: ['update:patch', 'auto-merge'],
      applyPins: () =>
        Promise.resolve(
          new Error(
            'the release notes list 0 ghcr.io/zgeoff/nixie digests under ## Images, want 1',
          ),
        ),
    },
  );

  const refs = await ctx.origin.git([
    '--git-dir',
    ctx.origin.origin,
    'for-each-ref',
    '--format=%(refname)',
  ]);

  expect(status).toBe(1);
  expect(ctx.printOut).not.toHaveBeenCalled();

  expect(ctx.printErr.mock.calls).toStrictEqual([
    ['the release notes list 0 ghcr.io/zgeoff/nixie digests under ## Images, want 1\n'],
  ]);

  expect(refs).toBe('refs/heads/main');
  expect(stub.calls.filter((call) => call.argv[0] === 'gh')).toStrictEqual([]);
});

test('it refuses a label it does not manage', async () => {
  const ctx = await setupTest();

  const stub = buildStubRunner(
    buildStubReleaseGH({}),
    buildRealProgramHandler(['git'], ctx.origin.env),
  );

  const status = await openReleaseBumpPR(
    {
      cwd: ctx.origin.seed,
      env: ctx.origin.env,
      run: stub.run,
      printOut: ctx.printOut,
      printErr: ctx.printErr,
    },
    {
      dependency: 'nixie',
      version: '0.7.1',
      body: 'Bumps nixie to 0.7.1.\n',
      labels: ['update:patch', 'ship-it'],
      applyPins: () => Promise.resolve(new Error('the pin ran')),
    },
  );

  expect(status).toBe(2);
  expect(ctx.printOut).not.toHaveBeenCalled();
  expect(ctx.printErr.mock.calls).toStrictEqual([["not a release bump label: 'ship-it'\n"]]);
  expect(stub.calls).toStrictEqual([]);
});

test("it keeps a person's needs-review hold on an unchanged branch", async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.origin.seed, 'pins'), 'imp 1.0.0\n');

  await ctx.origin.git(['-C', ctx.origin.seed, 'add', '-A']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'commit', '-qm', 'add the pins']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'push', '-q', 'origin', 'main']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'switch', '-qc', 'release-check/imp']);

  await writeFile(join(ctx.origin.seed, 'pins'), 'imp 1.0.1\n');

  await ctx.origin.git(['-C', ctx.origin.seed, 'commit', '-qam', 'chore(imp): bump imp to 1.0.1']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'push', '-q', 'origin', 'release-check/imp']);
  await ctx.origin.git(['clone', '-q', ctx.origin.origin, ctx.clone]);

  const stub = buildStubRunner(
    buildStubReleaseGH({
      openPRs: [
        {
          autoMergeRequest: null,
          isCrossRepository: false,
          labels: [{ name: 'needs-review' }, { name: 'update:patch' }],
          number: 14,
          url: 'https://github.com/zgeoff/cloud/pull/14',
        },
      ],
    }),
    buildRealProgramHandler(['git'], ctx.origin.env),
  );

  const status = await openReleaseBumpPR(
    {
      cwd: ctx.clone,
      env: ctx.origin.env,
      run: stub.run,
      printOut: ctx.printOut,
      printErr: ctx.printErr,
    },
    {
      dependency: 'imp',
      version: '1.0.1',
      body: 'Bumps imp to 1.0.1.\n',
      labels: ['update:patch', 'auto-merge'],
      applyPins: async () => {
        await writeFile(join(ctx.clone, 'pins'), 'imp 1.0.1\n');

        return undefined;
      },
    },
  );

  expect(status).toBe(0);

  expect(ctx.printOut.mock.calls).toStrictEqual([
    ['https://github.com/zgeoff/cloud/pull/14 already bumps imp to 1.0.1\n'],
  ]);

  expect(ctx.printErr).not.toHaveBeenCalled();

  expect(stub.calls.filter((call) => call.argv[0] === 'gh').map((call) => call.argv)).toStrictEqual(
    [
      [
        'gh',
        'pr',
        'list',
        '--repo',
        'zgeoff/cloud',
        '--head',
        'release-check/imp',
        '--state',
        'open',
        '--json',
        'number,url,autoMergeRequest,labels,headRefOid,isCrossRepository',
      ],
      [
        'gh',
        'label',
        'create',
        'update:patch',
        '--repo',
        'zgeoff/cloud',
        '--force',
        '--color',
        '0e8a16',
        '--description',
        'a patch release',
      ],
      [
        'gh',
        'label',
        'create',
        'auto-merge',
        '--repo',
        'zgeoff/cloud',
        '--force',
        '--color',
        '0e8a16',
        '--description',
        'merges on its own once its checks pass',
      ],
    ],
  );
});

test('it keeps a bump closed that a person closed at the same head', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.origin.seed, 'pins'), 'imp 1.0.0\n');

  await ctx.origin.git(['-C', ctx.origin.seed, 'add', '-A']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'commit', '-qm', 'add the pins']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'push', '-q', 'origin', 'main']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'switch', '-qc', 'release-check/imp']);

  await writeFile(join(ctx.origin.seed, 'pins'), 'imp 1.0.1\n');

  await ctx.origin.git(['-C', ctx.origin.seed, 'commit', '-qam', 'chore(imp): bump imp to 1.0.1']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'push', '-q', 'origin', 'release-check/imp']);
  await ctx.origin.git(['clone', '-q', ctx.origin.origin, ctx.clone]);

  const head = await ctx.origin.git([
    '--git-dir',
    ctx.origin.origin,
    'rev-parse',
    'release-check/imp',
  ]);

  const stub = buildStubRunner(
    buildStubReleaseGH({
      closedPRs: [{ headRefOid: head, isCrossRepository: false, number: 15 }],
    }),
    buildRealProgramHandler(['git'], ctx.origin.env),
  );

  const status = await openReleaseBumpPR(
    {
      cwd: ctx.clone,
      env: ctx.origin.env,
      run: stub.run,
      printOut: ctx.printOut,
      printErr: ctx.printErr,
    },
    {
      dependency: 'imp',
      version: '1.0.1',
      body: 'Bumps imp to 1.0.1.\n',
      labels: ['update:patch', 'auto-merge'],
      applyPins: async () => {
        await writeFile(join(ctx.clone, 'pins'), 'imp 1.0.1\n');

        return undefined;
      },
    },
  );

  expect(status).toBe(0);

  expect(ctx.printOut.mock.calls).toStrictEqual([
    ['#15 was closed with this bump; delete release-check/imp to open it again\n'],
  ]);

  expect(ctx.printErr).not.toHaveBeenCalled();

  expect(stub.calls.filter((call) => call.argv[0] === 'gh').map((call) => call.argv)).toStrictEqual(
    [
      [
        'gh',
        'pr',
        'list',
        '--repo',
        'zgeoff/cloud',
        '--head',
        'release-check/imp',
        '--state',
        'open',
        '--json',
        'number,url,autoMergeRequest,labels,headRefOid,isCrossRepository',
      ],
      [
        'gh',
        'label',
        'create',
        'update:patch',
        '--repo',
        'zgeoff/cloud',
        '--force',
        '--color',
        '0e8a16',
        '--description',
        'a patch release',
      ],
      [
        'gh',
        'label',
        'create',
        'auto-merge',
        '--repo',
        'zgeoff/cloud',
        '--force',
        '--color',
        '0e8a16',
        '--description',
        'merges on its own once its checks pass',
      ],
      [
        'gh',
        'pr',
        'list',
        '--repo',
        'zgeoff/cloud',
        '--head',
        'release-check/imp',
        '--state',
        'closed',
        '--json',
        'number,url,autoMergeRequest,labels,headRefOid,isCrossRepository',
      ],
    ],
  );
});

test('it stops without a push or a pull request when the closed lookup fails', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.origin.seed, 'pins'), 'imp 1.0.0\n');

  await ctx.origin.git(['-C', ctx.origin.seed, 'add', '-A']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'commit', '-qm', 'add the pins']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'push', '-q', 'origin', 'main']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'switch', '-qc', 'release-check/imp']);

  await writeFile(join(ctx.origin.seed, 'pins'), 'imp 1.0.1\n');

  await ctx.origin.git(['-C', ctx.origin.seed, 'commit', '-qam', 'chore(imp): bump imp to 1.0.1']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'push', '-q', 'origin', 'release-check/imp']);
  await ctx.origin.git(['clone', '-q', ctx.origin.origin, ctx.clone]);

  const head = await ctx.origin.git([
    '--git-dir',
    ctx.origin.origin,
    'rev-parse',
    'release-check/imp',
  ]);

  const stub = buildStubRunner(
    (call) =>
      call.argv.join(' ').includes('--state closed')
        ? { exitCode: 1, stderr: 'HTTP 502: Bad Gateway (https://api.github.com/graphql)\n' }
        : undefined,
    buildStubReleaseGH({}),
    buildRealProgramHandler(['git'], ctx.origin.env),
  );

  const status = await openReleaseBumpPR(
    {
      cwd: ctx.clone,
      env: ctx.origin.env,
      run: stub.run,
      printOut: ctx.printOut,
      printErr: ctx.printErr,
    },
    {
      dependency: 'imp',
      version: '1.0.1',
      body: 'Bumps imp to 1.0.1.\n',
      labels: ['update:patch', 'auto-merge'],
      applyPins: async () => {
        await writeFile(join(ctx.clone, 'pins'), 'imp 1.0.1\n');

        return undefined;
      },
    },
  );

  expect(status).toBe(1);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    ['HTTP 502: Bad Gateway (https://api.github.com/graphql)\n'],
  ]);

  expect(
    stub.calls
      .filter((call) => call.argv[0] === 'gh')
      .map((call) => call.argv.slice(1, 3).join(' ')),
  ).toStrictEqual(['pr list', 'label create', 'label create', 'pr list']);

  const after = await ctx.origin.git([
    '--git-dir',
    ctx.origin.origin,
    'rev-parse',
    'release-check/imp',
  ]);

  expect(after).toBe(head);
});

test("it opens its own pull request past a fork's with the same branch name", async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.origin.seed, 'pins'), 'nixie 0.7.0\n');

  await ctx.origin.git(['-C', ctx.origin.seed, 'add', '-A']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'commit', '-qm', 'add the pins']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'push', '-q', 'origin', 'main']);
  await ctx.origin.git(['clone', '-q', ctx.origin.origin, ctx.clone]);

  const stub = buildStubRunner(
    buildStubReleaseGH({
      openPRs: [
        {
          autoMergeRequest: null,
          isCrossRepository: true,
          labels: [],
          number: 31,
          url: 'https://github.com/zgeoff/cloud/pull/31',
        },
      ],
    }),
    buildRealProgramHandler(['git'], ctx.origin.env),
  );

  const status = await openReleaseBumpPR(
    {
      cwd: ctx.clone,
      env: ctx.origin.env,
      run: stub.run,
      printOut: ctx.printOut,
      printErr: ctx.printErr,
    },
    {
      dependency: 'nixie',
      version: '0.7.1',
      body: 'Bumps nixie to 0.7.1.\n',
      labels: ['update:patch', 'auto-merge'],
      applyPins: async () => {
        await writeFile(join(ctx.clone, 'pins'), 'nixie 0.7.1\n');

        return undefined;
      },
    },
  );

  expect(status).toBe(0);
  expect(ctx.printOut.mock.calls).toStrictEqual([['https://github.com/zgeoff/cloud/pull/200\n']]);
  expect(ctx.printErr).not.toHaveBeenCalled();

  expect(stub.calls.filter((call) => call.argv[0] === 'gh').map((call) => call.argv)).toStrictEqual(
    [
      [
        'gh',
        'pr',
        'list',
        '--repo',
        'zgeoff/cloud',
        '--head',
        'release-check/nixie',
        '--state',
        'open',
        '--json',
        'number,url,autoMergeRequest,labels,headRefOid,isCrossRepository',
      ],
      [
        'gh',
        'label',
        'create',
        'update:patch',
        '--repo',
        'zgeoff/cloud',
        '--force',
        '--color',
        '0e8a16',
        '--description',
        'a patch release',
      ],
      [
        'gh',
        'label',
        'create',
        'auto-merge',
        '--repo',
        'zgeoff/cloud',
        '--force',
        '--color',
        '0e8a16',
        '--description',
        'merges on its own once its checks pass',
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
        'release-check/nixie',
        '--title',
        'chore(nixie): bump nixie to 0.7.1',
        '--body-file',
        '-',
        '--label',
        'update:patch,auto-merge',
      ],
    ],
  );
});

test('it refuses a working tree that another pin left changed', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.origin.seed, 'pins'), 'nixie 0.7.0\nimp 1.0.0\n');

  await ctx.origin.git(['-C', ctx.origin.seed, 'add', '-A']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'commit', '-qm', 'add the pins']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'push', '-q', 'origin', 'main']);
  await ctx.origin.git(['clone', '-q', ctx.origin.origin, ctx.clone]);

  await writeFile(join(ctx.clone, 'pins'), 'nixie 0.7.0\nimp 1.0.1\n');

  const stub = buildStubRunner(
    buildStubReleaseGH({}),
    buildRealProgramHandler(['git'], ctx.origin.env),
  );

  const status = await openReleaseBumpPR(
    {
      cwd: ctx.clone,
      env: ctx.origin.env,
      run: stub.run,
      printOut: ctx.printOut,
      printErr: ctx.printErr,
    },
    {
      dependency: 'nixie',
      version: '0.7.1',
      body: 'Bumps nixie to 0.7.1.\n',
      labels: ['update:patch', 'auto-merge'],
      applyPins: async () => {
        await writeFile(join(ctx.clone, 'pins'), 'nixie 0.7.1\nimp 1.0.1\n');

        return undefined;
      },
    },
  );

  const pins = await readFile(join(ctx.clone, 'pins'), 'utf8');

  const refs = await ctx.origin.git([
    '--git-dir',
    ctx.origin.origin,
    'for-each-ref',
    '--format=%(refname)',
  ]);

  expect(status).toBe(1);
  expect(ctx.printOut).not.toHaveBeenCalled();

  expect(ctx.printErr.mock.calls).toStrictEqual([
    ['the working tree has uncommitted changes; commit or discard them first\n'],
  ]);

  expect(pins).toBe('nixie 0.7.0\nimp 1.0.1\n');
  expect(refs).toBe('refs/heads/main');
  expect(stub.calls.filter((call) => call.argv[0] === 'gh')).toStrictEqual([]);
});

test("it keeps a person's needs-review hold when main changed another pin in the same file", async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.origin.seed, 'pins'), 'atc 4.2.0\nimp-base 1.0.0\n');

  await ctx.origin.git(['-C', ctx.origin.seed, 'add', '-A']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'commit', '-qm', 'add the pins']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'push', '-q', 'origin', 'main']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'switch', '-qc', 'release-check/atc']);

  await writeFile(join(ctx.origin.seed, 'pins'), 'atc 4.2.1\nimp-base 1.0.0\n');

  await ctx.origin.git(['-C', ctx.origin.seed, 'commit', '-qam', 'chore(atc): bump atc to 4.2.1']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'push', '-q', 'origin', 'release-check/atc']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'switch', '-q', 'main']);

  await writeFile(join(ctx.origin.seed, 'pins'), 'atc 4.2.0\nimp-base 1.0.1\n');

  await ctx.origin.git(['-C', ctx.origin.seed, 'commit', '-qam', 'chore(imp): bump imp to 1.0.1']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'push', '-q', 'origin', 'main']);
  await ctx.origin.git(['clone', '-q', ctx.origin.origin, ctx.clone]);

  const stub = buildStubRunner(
    buildStubReleaseGH({
      openPRs: [
        {
          autoMergeRequest: null,
          isCrossRepository: false,
          labels: [{ name: 'needs-review' }, { name: 'update:patch' }],
          number: 14,
          url: 'https://github.com/zgeoff/cloud/pull/14',
        },
      ],
    }),
    buildRealProgramHandler(['git'], ctx.origin.env),
  );

  const status = await openReleaseBumpPR(
    {
      cwd: ctx.clone,
      env: ctx.origin.env,
      run: stub.run,
      printOut: ctx.printOut,
      printErr: ctx.printErr,
    },
    {
      dependency: 'atc',
      version: '4.2.1',
      body: 'Bumps atc to 4.2.1.\n',
      labels: ['update:patch', 'auto-merge'],
      applyPins: async () => {
        const pins = await readFile(join(ctx.clone, 'pins'), 'utf8');

        await writeFile(join(ctx.clone, 'pins'), pins.replace(/^atc .*$/mu, 'atc 4.2.1'));

        return undefined;
      },
    },
  );

  const pins = await ctx.origin.git([
    '--git-dir',
    ctx.origin.origin,
    'show',
    'release-check/atc:pins',
  ]);

  const log = await ctx.origin.git([
    '--git-dir',
    ctx.origin.origin,
    'log',
    '--format=%s',
    'main..release-check/atc',
  ]);

  expect(status).toBe(0);
  expect(ctx.printOut.mock.calls).toStrictEqual([['https://github.com/zgeoff/cloud/pull/14\n']]);
  expect(ctx.printErr).not.toHaveBeenCalled();
  expect(pins).toBe('atc 4.2.1\nimp-base 1.0.1');
  expect(log).toBe('chore(atc): bump atc to 4.2.1');

  expect(stub.calls.filter((call) => call.argv[0] === 'gh').map((call) => call.argv)).toStrictEqual(
    [
      [
        'gh',
        'pr',
        'list',
        '--repo',
        'zgeoff/cloud',
        '--head',
        'release-check/atc',
        '--state',
        'open',
        '--json',
        'number,url,autoMergeRequest,labels,headRefOid,isCrossRepository',
      ],
      [
        'gh',
        'label',
        'create',
        'update:patch',
        '--repo',
        'zgeoff/cloud',
        '--force',
        '--color',
        '0e8a16',
        '--description',
        'a patch release',
      ],
      [
        'gh',
        'label',
        'create',
        'auto-merge',
        '--repo',
        'zgeoff/cloud',
        '--force',
        '--color',
        '0e8a16',
        '--description',
        'merges on its own once its checks pass',
      ],
      [
        'gh',
        'pr',
        'edit',
        '14',
        '--repo',
        'zgeoff/cloud',
        '--title',
        'chore(atc): bump atc to 4.2.1',
        '--body-file',
        '-',
      ],
    ],
  );
});

test("it drops a person's needs-review hold when a later release replaces the bump", async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.origin.seed, 'pins'), 'atc 4.2.0\nimp-base 1.0.0\n');

  await ctx.origin.git(['-C', ctx.origin.seed, 'add', '-A']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'commit', '-qm', 'add the pins']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'push', '-q', 'origin', 'main']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'switch', '-qc', 'release-check/atc']);

  await writeFile(join(ctx.origin.seed, 'pins'), 'atc 4.2.1\nimp-base 1.0.0\n');

  await ctx.origin.git(['-C', ctx.origin.seed, 'commit', '-qam', 'chore(atc): bump atc to 4.2.1']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'push', '-q', 'origin', 'release-check/atc']);
  await ctx.origin.git(['clone', '-q', ctx.origin.origin, ctx.clone]);

  const stub = buildStubRunner(
    buildStubReleaseGH({
      openPRs: [
        {
          autoMergeRequest: null,
          isCrossRepository: false,
          labels: [{ name: 'needs-review' }, { name: 'update:patch' }],
          number: 14,
          url: 'https://github.com/zgeoff/cloud/pull/14',
        },
      ],
    }),
    buildRealProgramHandler(['git'], ctx.origin.env),
  );

  const status = await openReleaseBumpPR(
    {
      cwd: ctx.clone,
      env: ctx.origin.env,
      run: stub.run,
      printOut: ctx.printOut,
      printErr: ctx.printErr,
    },
    {
      dependency: 'atc',
      version: '4.2.2',
      body: 'Bumps atc to 4.2.2.\n',
      labels: ['update:patch', 'auto-merge'],
      applyPins: async () => {
        const pins = await readFile(join(ctx.clone, 'pins'), 'utf8');

        await writeFile(join(ctx.clone, 'pins'), pins.replace(/^atc .*$/mu, 'atc 4.2.2'));

        return undefined;
      },
    },
  );

  const log = await ctx.origin.git([
    '--git-dir',
    ctx.origin.origin,
    'log',
    '--format=%s',
    'main..release-check/atc',
  ]);

  expect(status).toBe(0);
  expect(ctx.printOut.mock.calls).toStrictEqual([['https://github.com/zgeoff/cloud/pull/14\n']]);
  expect(ctx.printErr).not.toHaveBeenCalled();
  expect(log).toBe('chore(atc): bump atc to 4.2.2');

  expect(stub.calls.filter((call) => call.argv[0] === 'gh').map((call) => call.argv)).toStrictEqual(
    [
      [
        'gh',
        'pr',
        'list',
        '--repo',
        'zgeoff/cloud',
        '--head',
        'release-check/atc',
        '--state',
        'open',
        '--json',
        'number,url,autoMergeRequest,labels,headRefOid,isCrossRepository',
      ],
      [
        'gh',
        'label',
        'create',
        'update:patch',
        '--repo',
        'zgeoff/cloud',
        '--force',
        '--color',
        '0e8a16',
        '--description',
        'a patch release',
      ],
      [
        'gh',
        'label',
        'create',
        'auto-merge',
        '--repo',
        'zgeoff/cloud',
        '--force',
        '--color',
        '0e8a16',
        '--description',
        'merges on its own once its checks pass',
      ],
      [
        'gh',
        'pr',
        'edit',
        '14',
        '--repo',
        'zgeoff/cloud',
        '--add-label',
        'auto-merge',
        '--remove-label',
        'needs-review',
      ],
      [
        'gh',
        'pr',
        'edit',
        '14',
        '--repo',
        'zgeoff/cloud',
        '--title',
        'chore(atc): bump atc to 4.2.2',
        '--body-file',
        '-',
      ],
    ],
  );
});

test('it keeps a rejected release closed when main changed another pin in the same file', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.origin.seed, 'pins'), 'atc 4.2.0\nimp-base 1.0.0\n');

  await ctx.origin.git(['-C', ctx.origin.seed, 'add', '-A']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'commit', '-qm', 'add the pins']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'push', '-q', 'origin', 'main']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'switch', '-qc', 'release-check/atc']);

  await writeFile(join(ctx.origin.seed, 'pins'), 'atc 4.2.1\nimp-base 1.0.0\n');

  await ctx.origin.git(['-C', ctx.origin.seed, 'commit', '-qam', 'chore(atc): bump atc to 4.2.1']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'push', '-q', 'origin', 'release-check/atc']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'switch', '-q', 'main']);

  await writeFile(join(ctx.origin.seed, 'pins'), 'atc 4.2.0\nimp-base 1.0.1\n');

  await ctx.origin.git(['-C', ctx.origin.seed, 'commit', '-qam', 'chore(imp): bump imp to 1.0.1']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'push', '-q', 'origin', 'main']);
  await ctx.origin.git(['clone', '-q', ctx.origin.origin, ctx.clone]);

  const head = await ctx.origin.git([
    '--git-dir',
    ctx.origin.origin,
    'rev-parse',
    'release-check/atc',
  ]);

  const stub = buildStubRunner(
    buildStubReleaseGH({
      closedPRs: [{ headRefOid: head, isCrossRepository: false, number: 15 }],
    }),
    buildRealProgramHandler(['git'], ctx.origin.env),
  );

  const status = await openReleaseBumpPR(
    {
      cwd: ctx.clone,
      env: ctx.origin.env,
      run: stub.run,
      printOut: ctx.printOut,
      printErr: ctx.printErr,
    },
    {
      dependency: 'atc',
      version: '4.2.1',
      body: 'Bumps atc to 4.2.1.\n',
      labels: ['update:patch', 'auto-merge'],
      applyPins: async () => {
        const pins = await readFile(join(ctx.clone, 'pins'), 'utf8');

        await writeFile(join(ctx.clone, 'pins'), pins.replace(/^atc .*$/mu, 'atc 4.2.1'));

        return undefined;
      },
    },
  );

  const after = await ctx.origin.git([
    '--git-dir',
    ctx.origin.origin,
    'rev-parse',
    'release-check/atc',
  ]);

  expect(status).toBe(0);

  expect(ctx.printOut.mock.calls).toStrictEqual([
    ['#15 was closed with this bump; delete release-check/atc to open it again\n'],
  ]);

  expect(ctx.printErr).not.toHaveBeenCalled();
  expect(after).toBe(head);

  expect(stub.calls.filter((call) => call.argv[0] === 'gh').map((call) => call.argv)).toStrictEqual(
    [
      [
        'gh',
        'pr',
        'list',
        '--repo',
        'zgeoff/cloud',
        '--head',
        'release-check/atc',
        '--state',
        'open',
        '--json',
        'number,url,autoMergeRequest,labels,headRefOid,isCrossRepository',
      ],
      [
        'gh',
        'label',
        'create',
        'update:patch',
        '--repo',
        'zgeoff/cloud',
        '--force',
        '--color',
        '0e8a16',
        '--description',
        'a patch release',
      ],
      [
        'gh',
        'label',
        'create',
        'auto-merge',
        '--repo',
        'zgeoff/cloud',
        '--force',
        '--color',
        '0e8a16',
        '--description',
        'merges on its own once its checks pass',
      ],
      [
        'gh',
        'pr',
        'list',
        '--repo',
        'zgeoff/cloud',
        '--head',
        'release-check/atc',
        '--state',
        'closed',
        '--json',
        'number,url,autoMergeRequest,labels,headRefOid,isCrossRepository',
      ],
    ],
  );
});

test('it opens a later release after a person rejected the one before', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.origin.seed, 'pins'), 'atc 4.2.0\nimp-base 1.0.0\n');

  await ctx.origin.git(['-C', ctx.origin.seed, 'add', '-A']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'commit', '-qm', 'add the pins']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'push', '-q', 'origin', 'main']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'switch', '-qc', 'release-check/atc']);

  await writeFile(join(ctx.origin.seed, 'pins'), 'atc 4.2.1\nimp-base 1.0.0\n');

  await ctx.origin.git(['-C', ctx.origin.seed, 'commit', '-qam', 'chore(atc): bump atc to 4.2.1']);
  await ctx.origin.git(['-C', ctx.origin.seed, 'push', '-q', 'origin', 'release-check/atc']);
  await ctx.origin.git(['clone', '-q', ctx.origin.origin, ctx.clone]);

  const head = await ctx.origin.git([
    '--git-dir',
    ctx.origin.origin,
    'rev-parse',
    'release-check/atc',
  ]);

  const stub = buildStubRunner(
    buildStubReleaseGH({
      closedPRs: [{ headRefOid: head, isCrossRepository: false, number: 15 }],
    }),
    buildRealProgramHandler(['git'], ctx.origin.env),
  );

  const status = await openReleaseBumpPR(
    {
      cwd: ctx.clone,
      env: ctx.origin.env,
      run: stub.run,
      printOut: ctx.printOut,
      printErr: ctx.printErr,
    },
    {
      dependency: 'atc',
      version: '4.2.2',
      body: 'Bumps atc to 4.2.2.\n',
      labels: ['update:patch', 'auto-merge'],
      applyPins: async () => {
        const pins = await readFile(join(ctx.clone, 'pins'), 'utf8');

        await writeFile(join(ctx.clone, 'pins'), pins.replace(/^atc .*$/mu, 'atc 4.2.2'));

        return undefined;
      },
    },
  );

  const log = await ctx.origin.git([
    '--git-dir',
    ctx.origin.origin,
    'log',
    '--format=%s',
    'main..release-check/atc',
  ]);

  expect(status).toBe(0);
  expect(ctx.printOut.mock.calls).toStrictEqual([['https://github.com/zgeoff/cloud/pull/200\n']]);
  expect(ctx.printErr).not.toHaveBeenCalled();
  expect(log).toBe('chore(atc): bump atc to 4.2.2');

  expect(stub.calls.filter((call) => call.argv[0] === 'gh').map((call) => call.argv)).toStrictEqual(
    [
      [
        'gh',
        'pr',
        'list',
        '--repo',
        'zgeoff/cloud',
        '--head',
        'release-check/atc',
        '--state',
        'open',
        '--json',
        'number,url,autoMergeRequest,labels,headRefOid,isCrossRepository',
      ],
      [
        'gh',
        'label',
        'create',
        'update:patch',
        '--repo',
        'zgeoff/cloud',
        '--force',
        '--color',
        '0e8a16',
        '--description',
        'a patch release',
      ],
      [
        'gh',
        'label',
        'create',
        'auto-merge',
        '--repo',
        'zgeoff/cloud',
        '--force',
        '--color',
        '0e8a16',
        '--description',
        'merges on its own once its checks pass',
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
        'release-check/atc',
        '--title',
        'chore(atc): bump atc to 4.2.2',
        '--body-file',
        '-',
        '--label',
        'update:patch,auto-merge',
      ],
    ],
  );
});
