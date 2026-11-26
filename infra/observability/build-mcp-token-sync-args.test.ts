import { expect, onTestFinished, test } from 'bun:test';
import { chmod, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { output, secret } from '@pulumi/pulumi';
import { buildMCPTokenSyncArgs } from './build-mcp-token-sync-args.ts';

test('it copies the key from stdin, does nothing on an update, runs again only for a new token, and logs only stderr', () => {
  const tokenID = output('1:7');
  const key = secret('glsa_example');

  expect(buildMCPTokenSyncArgs({ tokenID, key })).toStrictEqual({
    create: expect.any(String),
    stdin: key,
    update: ':',
    triggers: [tokenID],
    logging: 'stderr',
  });
});

test('it skips the copy with a message when GRAFANA_MCP_OP_TOKEN is unset', async () => {
  const ctx = await setupTest();

  const run = ctx.runCreate({});

  expect({
    exitCode: run.exitCode,
    stdout: run.stdout.toString(),
    stderr: run.stderr.toString(),
    opCalls: await ctx.readOpCalls(),
  }).toStrictEqual({
    exitCode: 0,
    stdout: '',
    stderr:
      'grafana-mcp-token-to-1password: skipped, GRAFANA_MCP_OP_TOKEN is unset; copy the token as docs/runbooks/workflows.md#rotate-a-credential describes\n',
    opCalls: '',
  });
});

test('it writes the key to the credential field of the agents grafana-mcp item with the GRAFANA_MCP_OP_TOKEN token', async () => {
  const ctx = await setupTest();

  const run = ctx.runCreate({ GRAFANA_MCP_OP_TOKEN: 'writer-token' });

  expect({
    exitCode: run.exitCode,
    stdout: run.stdout.toString(),
    stderr: run.stderr.toString(),
    opCalls: await ctx.readOpCalls(),
  }).toStrictEqual({
    exitCode: 0,
    stdout: '',
    stderr: '',
    opCalls:
      'token=writer-token args=item edit grafana-mcp --vault agents credential=glsa_example\n',
  });
});

test('it fails with its own message and prints none of the output of an op that cannot write the item', async () => {
  const ctx = await setupTest();

  const run = ctx.runCreate({ GRAFANA_MCP_OP_TOKEN: 'writer-token', FAKE_OP_FAILS: '1' });

  expect({
    exitCode: run.exitCode,
    stdout: run.stdout.toString(),
    stderr: run.stderr.toString(),
  }).toStrictEqual({
    exitCode: 1,
    stdout: '',
    stderr:
      'grafana-mcp-token-to-1password: op could not write the grafana-mcp item in the agents vault\n',
  });
});

interface TestContext {
  readonly runCreate: (environment: Record<string, string>) => Bun.SyncSubprocess<'pipe', 'pipe'>;
  readonly readOpCalls: () => Promise<string>;
}

async function setupTest(): Promise<TestContext> {
  const directory = await mkdtemp(join(tmpdir(), 'mcp-token-sync-'));

  const opCalls = join(directory, 'op-calls');

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  // a stand-in for op that records its token and arguments, and echoes the arguments on a failure
  await writeFile(
    join(directory, 'op'),
    [
      '#!/usr/bin/env bash',
      `echo "token=$OP_SERVICE_ACCOUNT_TOKEN args=$*" >> '${opCalls}'`,
      'if [ -n "$FAKE_OP_FAILS" ]; then echo "op failed: $*"; echo "op failed: $*" >&2; exit 1; fi',
      '',
    ].join('\n'),
  );

  await chmod(join(directory, 'op'), 0o755);
  await writeFile(opCalls, '');

  const args = buildMCPTokenSyncArgs({ tokenID: output('1:7'), key: output('glsa_example') });

  expect(args.create).toBeTypeOf('string');

  return {
    runCreate: (environment) =>
      Bun.spawnSync(['bash', '-c', typeof args.create === 'string' ? args.create : ''], {
        env: {
          PATH: `${directory}:/usr/bin:/bin`,
          OP_SERVICE_ACCOUNT_TOKEN: 'deploy-token',
          ...environment,
        },
        stdin: Buffer.from('glsa_example'),
        stdout: 'pipe',
        stderr: 'pipe',
      }),
    readOpCalls: () => readFile(opCalls, 'utf8'),
  };
}
