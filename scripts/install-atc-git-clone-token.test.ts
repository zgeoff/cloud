import { expect, test } from 'bun:test';
import { installATCGitCloneToken } from './install-atc-git-clone-token.ts';
import { readHostScript } from './read-host-script.ts';
import { buildStubOp } from './test-utils/build-stub-op.ts';
import type { StubHandler } from './test-utils/build-stub-runner.ts';
import { buildStubRunner } from './test-utils/build-stub-runner.ts';

interface SetupConfig {
  // the host check's exit codes, one per call, in order
  readonly checkExits: readonly number[];
  readonly env?: Readonly<Record<string, string>>;
}

async function setupTest(config: SetupConfig) {
  const out: string[] = [];
  const err: string[] = [];
  const checkExits = [...config.checkExits];
  const op = buildStubOp({ vaults: { cloud: { 'boxxy-github-token': 'ghp_fixture_token' } } });

  const checkBytes = await readHostScript('check-atc-git-clone-token.sh');
  const writeBytes = await readHostScript('write-atc-git-clone-token.sh');

  const checkScript = checkBytes.toString();

  const host: StubHandler = (call) => {
    if (call.argv[0] !== 'ssh') {
      return;
    }

    return call.stdin.startsWith(checkScript)
      ? { exitCode: checkExits.shift() ?? 97 }
      : { exitCode: 0, stdout: '' };
  };

  const runner = buildStubRunner(op.answer, host);

  const run = (env: Readonly<Record<string, string>>) =>
    installATCGitCloneToken({
      run: runner.run,
      env: {
        OP_SERVICE_ACCOUNT_TOKEN: 'ops_fixture',
        ATC_GIT_CLONE_CHECK_REPO: 'acme/widgets',
        ...env,
      },
      printOut: (text) => {
        out.push(text);
      },
      printErr: (text) => {
        err.push(text);
      },
    });

  return {
    out,
    err,
    calls: runner.calls,
    checkScript,
    writeScript: writeBytes.toString(),
    run: () => run(config.env ?? {}),
  };
}

test('it skips a host file whose token reads the repo, and reads nothing from 1Password', async () => {
  const ctx = await setupTest({ checkExits: [0] });
  const exitCode = await ctx.run();

  expect(exitCode).toBe(0);
  expect(ctx.out.join('')).toContain('skip: the host file reads the repo');
  expect(ctx.calls.map((call) => call.argv[0])).toStrictEqual(['ssh']);

  const [check] = ctx.calls;

  expect(check?.argv.at(-1)).toBe("'bash' '-s' '--' '/var/lib/atc-daemon-secrets' 'acme/widgets'");
});

test.each([
  { exitCode: 120, case: 'absent' },
  { exitCode: 122, case: 'refused by GitHub' },
])('it writes the 1Password token over ssh stdin when the host file is $case', async (row) => {
  const ctx = await setupTest({ checkExits: [row.exitCode, 0] });
  const exitCode = await ctx.run();

  expect(exitCode).toBe(0);
  expect(ctx.out.join('')).toContain('ok: the host file reads the repo');

  const write = ctx.calls.find((call) => call.stdin.startsWith(ctx.writeScript));

  expect(write?.stdin).toBe(`${ctx.writeScript}ghp_fixture_token\n`);
  expect(write?.argv.at(-1)).toBe("'bash' '-s' '--' '/var/lib/atc-daemon-secrets'");
});

test('it keeps the token out of every argv, output line and error line', async () => {
  const ctx = await setupTest({ checkExits: [120, 0] });

  await ctx.run();

  const argvs = ctx.calls.map((call) => call.argv.join(' '));

  expect(argvs.filter((argv) => argv.includes('ghp_fixture_token'))).toStrictEqual([]);

  expect(
    [...ctx.out, ...ctx.err].filter((line) => line.includes('ghp_fixture_token')),
  ).toStrictEqual([]);
});

test('it fails when the token it wrote still does not read the repo', async () => {
  const ctx = await setupTest({ checkExits: [120, 122] });
  const exitCode = await ctx.run();

  expect(exitCode).toBe(1);
  expect(ctx.err.join('')).toContain('does not read the repo');
});

test('it changes nothing when the check cannot run', async () => {
  const ctx = await setupTest({ checkExits: [255] });
  const exitCode = await ctx.run();

  expect(exitCode).toBe(1);
  expect(ctx.calls.map((call) => call.argv[0])).toStrictEqual(['ssh']);
});

test('it fails with a usage message when no check repo is set', async () => {
  const ctx = await setupTest({ checkExits: [], env: { ATC_GIT_CLONE_CHECK_REPO: '' } });
  const exitCode = await ctx.run();

  expect(exitCode).toBe(2);
  expect(ctx.err.join('')).toContain('ATC_GIT_CLONE_CHECK_REPO');
  expect(ctx.calls).toStrictEqual([]);
});
