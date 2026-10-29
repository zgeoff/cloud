import { expect, mock, onTestFinished, test } from 'bun:test';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildMockGHCheckRun } from '../test-utils/build-mock-gh-check-run.ts';
import { buildMockGHPRView } from '../test-utils/build-mock-gh-pr-view.ts';
import { buildStubReleaseGH } from '../test-utils/build-stub-release-gh.ts';
import { buildStubRunner } from '../test-utils/build-stub-runner.ts';
import { runReleaseBumpMerge } from './run-release-bump-merge.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'run-release-bump-merge-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  const summary = join(directory, 'summary.md');
  const eventPath = join(directory, 'event.json');

  // boot data: the runner creates the step summary before the step runs
  await writeFile(summary, '');

  const printOut = mock<(text: string) => void>();
  const printErr = mock<(text: string) => void>();
  const env = { GITHUB_EVENT_PATH: eventPath, GITHUB_STEP_SUMMARY: summary };

  return { summary, eventPath, env, printOut, printErr };
}

test('it merges a green bump and copies the decision to the summary', async () => {
  const ctx = await setupTest();

  await writeFile(
    ctx.eventPath,
    '{"action":"labeled","label":{"name":"auto-merge"},"pull_request":{"head":{"ref":"release-check/auto-mode","repo":{"full_name":"zgeoff/cloud"}}}}',
  );

  const view = buildMockGHPRView({
    author: { login: 'app/cloud-release-check' },
    labels: [{ name: 'update:patch' }, { name: 'auto-merge' }],
    files: [{ path: 'images/agent/Dockerfile' }, { path: 'scripts/release/release-pins.json' }],
    commits: [{ oid: '3333333', authors: [{ login: 'cloud-release-check[bot]' }] }],
    statusCheckRollup: [
      buildMockGHCheckRun({ workflowName: 'CI', name: 'checks' }),
      buildMockGHCheckRun({ workflowName: 'agent image', name: 'check' }),
    ],
  });

  const stub = buildStubRunner(
    buildStubReleaseGH({
      openPRs: [{ number: 31, isCrossRepository: false }],
      prViews: { 31: view },
    }),
  );

  const status = await runReleaseBumpMerge({
    env: {
      ...ctx.env,
      GITHUB_EVENT_NAME: 'pull_request_target',
      GITHUB_REPOSITORY: 'zgeoff/cloud',
      APP_LOGIN: 'app/cloud-release-check',
      MERGE_TOKEN: 'merge-token',
    },
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  const summary = await readFile(ctx.summary, 'utf8');

  expect(status).toBe(0);
  expect(ctx.printOut.mock.calls).toStrictEqual([[`merged #31 at ${view.headRefOid}\n`]]);
  expect(ctx.printErr).not.toHaveBeenCalled();
  expect(summary).toBe(`merged #31 at ${view.headRefOid}\n`);
});

test('it merges a relabelled bump while its own merge job runs on the head', async () => {
  const ctx = await setupTest();

  await writeFile(
    ctx.eventPath,
    '{"action":"labeled","label":{"name":"auto-merge"},"pull_request":{"head":{"ref":"release-check/atc","repo":{"full_name":"zgeoff/cloud"}}}}',
  );

  const view = buildMockGHPRView({
    author: { login: 'app/cloud-release-check' },
    labels: [{ name: 'update:minor' }, { name: 'auto-merge' }],
    files: [{ path: 'nixos/packages/atc.nix' }, { path: 'scripts/release/release-pins.json' }],
    commits: [{ oid: '7777777', authors: [{ login: 'cloud-release-check[bot]' }] }],
    statusCheckRollup: [
      buildMockGHCheckRun({ workflowName: 'CI', name: 'checks' }),
      buildMockGHCheckRun({ workflowName: 'NixOS checks', name: 'nixos' }),
      buildMockGHCheckRun({
        workflowName: 'release bump merge',
        name: 'merge',
        status: 'IN_PROGRESS',
        conclusion: null,
      }),
    ],
  });

  const stub = buildStubRunner(
    buildStubReleaseGH({
      openPRs: [{ number: 33, isCrossRepository: false }],
      prViews: { 33: view },
    }),
  );

  const status = await runReleaseBumpMerge({
    env: {
      ...ctx.env,
      GITHUB_EVENT_NAME: 'pull_request_target',
      GITHUB_REPOSITORY: 'zgeoff/cloud',
      APP_LOGIN: 'app/cloud-release-check',
      MERGE_TOKEN: 'merge-token',
    },
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(status).toBe(0);
  expect(ctx.printOut.mock.calls).toStrictEqual([[`merged #33 at ${view.headRefOid}\n`]]);
  expect(ctx.printErr).not.toHaveBeenCalled();
});

test('it reads its own pull request with GH_TOKEN and merges it at its head with the merge token', async () => {
  const ctx = await setupTest();

  await writeFile(
    ctx.eventPath,
    '{"workflow_run":{"event":"pull_request","head_branch":"release-check/nixie","head_repository":{"full_name":"zgeoff/cloud"}}}',
  );

  const view = buildMockGHPRView({
    author: { login: 'app/cloud-release-check' },
    headRefOid: '4444444444444444444444444444444444444444',
    labels: [{ name: 'auto-merge' }],
    files: [{ path: 'scripts/release/release-pins.json' }],
    commits: [{ oid: '4444444', authors: [{ login: 'cloud-release-check[bot]' }] }],
    statusCheckRollup: [buildMockGHCheckRun({ workflowName: 'CI', name: 'checks' })],
  });

  // a fork's pull request can have the same branch name, and gh lists it first here
  const stub = buildStubRunner(
    buildStubReleaseGH({
      openPRs: [
        { number: 40, isCrossRepository: true },
        { number: 41, isCrossRepository: false },
      ],
      prViews: { 41: view },
    }),
  );

  await runReleaseBumpMerge({
    env: {
      ...ctx.env,
      GITHUB_EVENT_NAME: 'workflow_run',
      GITHUB_REPOSITORY: 'zgeoff/cloud',
      GH_TOKEN: 'read-token',
      APP_LOGIN: 'app/cloud-release-check',
      MERGE_TOKEN: 'merge-token',
    },
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(
    stub.calls.map((call) => `GH_TOKEN=${call.options.env?.['GH_TOKEN']} ${call.argv.join(' ')}`),
  ).toStrictEqual([
    'GH_TOKEN=read-token gh pr list --repo zgeoff/cloud --head release-check/nixie --state open --json number,isCrossRepository',
    'GH_TOKEN=read-token gh pr view 41 --repo zgeoff/cloud --json author,isCrossRepository,headRefOid,labels,files,commits,statusCheckRollup',
    'GH_TOKEN=merge-token gh pr merge 41 --repo zgeoff/cloud --squash --match-head-commit 4444444444444444444444444444444444444444',
  ]);
});

test('it holds a pull request with the reason and merges nothing', async () => {
  const ctx = await setupTest();

  await writeFile(
    ctx.eventPath,
    '{"workflow_run":{"event":"pull_request","head_branch":"release-check/auto-mode","head_repository":{"full_name":"zgeoff/cloud"}}}',
  );

  const view = buildMockGHPRView({
    author: { login: 'app/cloud-release-check' },
    labels: [{ name: 'update:patch' }, { name: 'auto-merge' }],
    files: [{ path: 'images/agent/Dockerfile' }, { path: 'nixos/packages/atc.nix' }],
    commits: [{ oid: '2222222', authors: [{ login: 'cloud-release-check[bot]' }] }],
  });

  const stub = buildStubRunner(
    buildStubReleaseGH({
      openPRs: [{ number: 8, isCrossRepository: false }],
      prViews: { 8: view },
    }),
  );

  await runReleaseBumpMerge({
    env: {
      ...ctx.env,
      GITHUB_EVENT_NAME: 'workflow_run',
      GITHUB_REPOSITORY: 'zgeoff/cloud',
      APP_LOGIN: 'app/cloud-release-check',
      MERGE_TOKEN: 'merge-token',
    },
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  const summary = await readFile(ctx.summary, 'utf8');

  expect(summary).toBe(
    '#8 stays open: it changes nixos/packages/atc.nix, which no pin of its dependency writes\n',
  );

  expect(stub.calls.map((call) => call.argv.slice(0, 3))).toStrictEqual([
    ['gh', 'pr', 'list'],
    ['gh', 'pr', 'view'],
  ]);
});

test('it skips a branch that is not a release check branch without calling gh', async () => {
  const ctx = await setupTest();

  await writeFile(
    ctx.eventPath,
    '{"workflow_run":{"event":"pull_request","head_branch":"release-check/renovate","head_repository":{"full_name":"zgeoff/cloud"}}}',
  );

  const stub = buildStubRunner();

  const status = await runReleaseBumpMerge({
    env: {
      ...ctx.env,
      GITHUB_EVENT_NAME: 'workflow_run',
      GITHUB_REPOSITORY: 'zgeoff/cloud',
      APP_LOGIN: 'app/cloud-release-check',
      MERGE_TOKEN: 'merge-token',
    },
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(status).toBe(0);

  expect(ctx.printOut.mock.calls).toStrictEqual([
    ['release-check/renovate is not a release check branch\n'],
  ]);

  expect(stub.calls).toStrictEqual([]);
});

test('it skips a branch without an open pull request of its own', async () => {
  const ctx = await setupTest();

  await writeFile(
    ctx.eventPath,
    '{"workflow_run":{"event":"pull_request","head_branch":"release-check/nixie","head_repository":{"full_name":"zgeoff/cloud"}}}',
  );

  const stub = buildStubRunner(
    buildStubReleaseGH({ openPRs: [{ number: 40, isCrossRepository: true }] }),
  );

  const status = await runReleaseBumpMerge({
    env: {
      ...ctx.env,
      GITHUB_EVENT_NAME: 'workflow_run',
      GITHUB_REPOSITORY: 'zgeoff/cloud',
      APP_LOGIN: 'app/cloud-release-check',
      MERGE_TOKEN: 'merge-token',
    },
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  const summary = await readFile(ctx.summary, 'utf8');

  expect(status).toBe(0);
  expect(summary).toBe('release-check/nixie has no open pull request\n');
  expect(stub.calls).toHaveLength(1);
});

test('it starts no decision for an event that names no bump, and writes no summary', async () => {
  const ctx = await setupTest();

  await writeFile(
    ctx.eventPath,
    '{"action":"labeled","label":{"name":"needs-review"},"pull_request":{"head":{"ref":"release-check/atc","repo":{"full_name":"zgeoff/cloud"}}}}',
  );

  const stub = buildStubRunner();

  const status = await runReleaseBumpMerge({
    env: {
      ...ctx.env,
      GITHUB_EVENT_NAME: 'pull_request_target',
      GITHUB_REPOSITORY: 'zgeoff/cloud',
    },
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  const summary = await readFile(ctx.summary, 'utf8');

  expect(status).toBe(0);

  expect(ctx.printOut.mock.calls).toStrictEqual([
    ['this pull_request_target event starts no merge decision\n'],
  ]);

  expect(summary).toBe('');
  expect(stub.calls).toStrictEqual([]);
});

test('it fails without the app login once an event names a bump', async () => {
  const ctx = await setupTest();

  await writeFile(
    ctx.eventPath,
    '{"workflow_run":{"event":"pull_request","head_branch":"release-check/atc","head_repository":{"full_name":"zgeoff/cloud"}}}',
  );

  const stub = buildStubRunner();

  const status = await runReleaseBumpMerge({
    env: {
      ...ctx.env,
      GITHUB_EVENT_NAME: 'workflow_run',
      GITHUB_REPOSITORY: 'zgeoff/cloud',
      MERGE_TOKEN: 'merge-token',
    },
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(status).toBe(2);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    ['APP_LOGIN must name the release check app, as app/<slug>\n'],
  ]);

  expect(stub.calls).toStrictEqual([]);
});

test('it fails without the merge token once an event names a bump', async () => {
  const ctx = await setupTest();

  await writeFile(
    ctx.eventPath,
    '{"workflow_run":{"event":"pull_request","head_branch":"release-check/atc","head_repository":{"full_name":"zgeoff/cloud"}}}',
  );

  const stub = buildStubRunner();

  const status = await runReleaseBumpMerge({
    env: {
      ...ctx.env,
      GITHUB_EVENT_NAME: 'workflow_run',
      GITHUB_REPOSITORY: 'zgeoff/cloud',
      APP_LOGIN: 'app/cloud-release-check',
    },
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(status).toBe(2);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    ["MERGE_TOKEN must hold the release check app's token\n"],
  ]);

  expect(stub.calls).toStrictEqual([]);
});

test('it fails without a step summary before it reads anything', async () => {
  const ctx = await setupTest();

  const stub = buildStubRunner();

  const status = await runReleaseBumpMerge({
    env: {
      GITHUB_EVENT_NAME: 'workflow_run',
      GITHUB_EVENT_PATH: ctx.eventPath,
      GITHUB_REPOSITORY: 'zgeoff/cloud',
      APP_LOGIN: 'app/cloud-release-check',
      MERGE_TOKEN: 'merge-token',
    },
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(status).toBe(2);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    ["GITHUB_STEP_SUMMARY must be set, as the workflow's runner sets it\n"],
  ]);

  expect(stub.calls).toStrictEqual([]);
});

test('it fails without the event file before calling gh', async () => {
  const ctx = await setupTest();

  const stub = buildStubRunner();

  const status = await runReleaseBumpMerge({
    env: {
      ...ctx.env,
      GITHUB_EVENT_NAME: 'pull_request_target',
      GITHUB_REPOSITORY: 'zgeoff/cloud',
      APP_LOGIN: 'app/cloud-release-check',
      MERGE_TOKEN: 'merge-token',
    },
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(status).toBe(1);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    [expect.toStartWith(`cannot read the event at ${ctx.eventPath}: `)],
  ]);

  expect(stub.calls).toStrictEqual([]);
});

test('it fails with the exit code and error of a failed gh call', async () => {
  const ctx = await setupTest();

  await writeFile(
    ctx.eventPath,
    '{"workflow_run":{"event":"pull_request","head_branch":"release-check/imp","head_repository":{"full_name":"zgeoff/cloud"}}}',
  );

  const stub = buildStubRunner(
    buildStubReleaseGH({ openPRs: [{ number: 12, isCrossRepository: false }] }),
  );

  const status = await runReleaseBumpMerge({
    env: {
      ...ctx.env,
      GITHUB_EVENT_NAME: 'workflow_run',
      GITHUB_REPOSITORY: 'zgeoff/cloud',
      APP_LOGIN: 'app/cloud-release-check',
      MERGE_TOKEN: 'merge-token',
    },
    run: stub.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  const summary = await readFile(ctx.summary, 'utf8');

  expect(status).toBe(1);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    [
      'GraphQL: Could not resolve to a PullRequest with the number of 12. (repository.pullRequest)\n',
    ],
  ]);

  expect(summary).toBe('');
});
