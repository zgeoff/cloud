import { expect, test } from 'bun:test';
import { checkATCCredentialsPreflight } from './check-atc-credentials-preflight.ts';
import { loadATCCredentialsContext } from './load-atc-credentials-context.ts';
import type { Runner } from './run-process.ts';
import { buildMockCredentialsHostScenario } from './test-utils/build-mock-credentials-host-scenario.ts';
import { buildMockImpSecret } from './test-utils/build-mock-imp-secret.ts';
import { buildStubCredentialTools } from './test-utils/build-stub-credential-tools.ts';

interface SetupConfig {
  readonly run: Runner;
}

async function setupTest(config: SetupConfig) {
  const out: string[] = [];
  const err: string[] = [];

  const context = await loadATCCredentialsContext({
    run: config.run,

    // a token in the environment, so the context reads no settings file
    env: { OP_SERVICE_ACCOUNT_TOKEN: 'ops_fixture_env' },
    printOut: (text) => {
      out.push(text);
    },
    printErr: (text) => {
      err.push(text);
    },
  });

  return { context, out, err };
}

test('it reads what exists, in this order, and checks the secrets mount and creates only the secrets directory', async () => {
  const tools = buildStubCredentialTools({
    op: { vaults: { cloud: { 'atc-daemon-token': 'fixture-bearer' } } },
    atcKey: { installed: true, zaiKey: 'zai_fixture_key' },
    host: buildMockCredentialsHostScenario(),
  });

  const ctx = await setupTest({ run: tools.run });

  await checkATCCredentialsPreflight(ctx.context);

  expect(tools.calls.map((call) => call.argv.join(' '))).toStrictEqual([
    'op vault get cloud --format json',
    'sh -c command -v atc-key > /dev/null',
    "ssh -o BatchMode=yes -o ConnectTimeout=15 root@geoffcloud 'true'",
    "ssh -o BatchMode=yes -o ConnectTimeout=15 root@geoffcloud 'docker' 'exec' 'imp-host' 'impz' 'info' '--json'",
    "ssh -o BatchMode=yes -o ConnectTimeout=15 root@geoffcloud 'docker' 'exec' 'imp-host' 'impz' 'secret' 'ls' '--json'",
    "ssh -o BatchMode=yes -o ConnectTimeout=15 root@geoffcloud 'docker' 'exec' 'imp-host' 'impz' 'token' 'ls' '--json'",
    'op item list --vault cloud --format json',
    `ssh -o BatchMode=yes -o ConnectTimeout=15 root@geoffcloud 'bash' '-c' 'mountpoint -q "$1" || { echo "$1 is not a mount point; nothing written" >&2; exit 1; }; install -d -m 0700 -o root -g root "$1"' 'bash' '/var/lib/atc-daemon-secrets'`,
    "ssh -o BatchMode=yes -o ConnectTimeout=15 root@geoffcloud 'ls' '/var/lib/atc-daemon-secrets'",
  ]);
});

test('it returns impd’s secrets and tokens, the item’s presence and the host’s files', async () => {
  const host = buildMockCredentialsHostScenario({
    files: { 'imp-token': { content: 'imp_fixture_saved\n', mode: '400' } },
  });

  const tools = buildStubCredentialTools({
    op: { vaults: { cloud: { 'atc-daemon-token': 'fixture-bearer' } } },
    atcKey: { installed: true, zaiKey: 'zai_fixture_key' },
    host,
  });

  const ctx = await setupTest({ run: tools.run });
  const preflight = await checkATCCredentialsPreflight(ctx.context);

  expect(preflight).toStrictEqual({
    secrets: host.secrets,
    tokens: host.tokens,
    hasItem: true,
    hostFiles: ['imp-token'],
  });

  expect(ctx.out.join('')).toBe(
    '\n== preflight\nok: 1Password vault cloud, atc-key, ssh root@geoffcloud, impd grantableTokens, /var/lib/atc-daemon-secrets\n',
  );
});

test('it stops with op’s message when the 1Password vault is missing', async () => {
  const tools = buildStubCredentialTools({
    op: { vaults: {} },
    atcKey: { installed: true, zaiKey: 'zai_fixture_key' },
    host: buildMockCredentialsHostScenario(),
  });

  const ctx = await setupTest({ run: tools.run });

  expect(checkATCCredentialsPreflight(ctx.context)).rejects.toMatchObject({
    exitCode: 1,
    message: '',
  });

  expect(tools.calls).toHaveLength(1);

  expect(ctx.err.join('')).toBe(
    `[ERROR] 2026/10/07 12:00:00 "cloud" isn't a vault in this account. Specify the vault with its ID or name.\n`,
  );
});

test('it stops before reaching the host when atc-key is not installed', async () => {
  const tools = buildStubCredentialTools({
    op: { vaults: { cloud: {} } },
    atcKey: { installed: false, zaiKey: '' },
    host: buildMockCredentialsHostScenario(),
  });

  const ctx = await setupTest({ run: tools.run });

  expect(checkATCCredentialsPreflight(ctx.context)).rejects.toMatchObject({
    exitCode: 1,
    message: 'atc-key is not on PATH; nothing changed',
  });

  expect(tools.calls.map((call) => call.argv[0])).toStrictEqual(['op', 'sh']);
});

test('it stops with ssh’s exit 255 when the host is unreachable', async () => {
  const tools = buildStubCredentialTools({
    op: { vaults: { cloud: {} } },
    atcKey: { installed: true, zaiKey: 'zai_fixture_key' },
    host: buildMockCredentialsHostScenario({ unreachable: true }),
  });

  const ctx = await setupTest({ run: tools.run });

  expect(checkATCCredentialsPreflight(ctx.context)).rejects.toMatchObject({ exitCode: 255 });
  expect(ctx.err.join('')).toBe('ssh: connect to host geoffcloud port 22: Connection refused\r\n');
});

test.each([
  ['an impd without the feature', { version: '0.26.0', features: { leases: true } }],
  [
    'an impd that turns the feature off',
    { version: '0.27.0', features: { grantableTokens: false } },
  ],
])('it stops before any change for %s', async (_label: string, info: unknown) => {
  const tools = buildStubCredentialTools({
    op: { vaults: { cloud: {} } },
    atcKey: { installed: true, zaiKey: 'zai_fixture_key' },
    host: buildMockCredentialsHostScenario({ info }),
  });

  const ctx = await setupTest({ run: tools.run });

  expect(checkATCCredentialsPreflight(ctx.context)).rejects.toMatchObject({
    exitCode: 1,
    message: 'impd lacks grantableTokens; nothing changed',
  });

  expect(tools.calls.at(-1)?.argv.slice(4)).toStrictEqual([
    'ConnectTimeout=15',
    'root@geoffcloud',
    "'docker' 'exec' 'imp-host' 'impz' 'info' '--json'",
  ]);
});

test('it stops before any change when impd lacks a secret that atc-cloud may grant', async () => {
  const tools = buildStubCredentialTools({
    op: { vaults: { cloud: {} } },
    atcKey: { installed: true, zaiKey: 'zai_fixture_key' },
    host: buildMockCredentialsHostScenario({
      secrets: [
        {
          ...buildMockImpSecret({
            name: 'claude-setup-token',
            rules: [{ host: 'api.anthropic.com', header: 'authorization', scheme: 'bearer' }],
          }),
        },
        {
          ...buildMockImpSecret({
            name: 'op-connect',
            rules: [{ host: 'op-connect.imp.internal', header: 'authorization', scheme: 'bearer' }],
          }),
        },
      ],
    }),
  });

  const ctx = await setupTest({ run: tools.run });

  expect(checkATCCredentialsPreflight(ctx.context)).rejects.toMatchObject({
    exitCode: 1,
    message:
      "impd lacks github-imp-agents, linear-imp-agents, which atc-cloud may grant; add each with\n'impz secret add' in imp-host, then rerun. Nothing changed",
  });

  expect(tools.calls.at(-1)?.argv.slice(4)).toStrictEqual([
    'ConnectTimeout=15',
    'root@geoffcloud',
    "'docker' 'exec' 'imp-host' 'impz' 'secret' 'ls' '--json'",
  ]);
});

test.each([
  ['impz info', 'info', "'docker' 'exec' 'imp-host' 'impz' 'info' '--json'"],
  ['impz secret ls', 'secret-ls', "'docker' 'exec' 'imp-host' 'impz' 'secret' 'ls' '--json'"],
  ['impz token ls', 'token-ls', "'docker' 'exec' 'imp-host' 'impz' 'token' 'ls' '--json'"],
] as const)(
  'it stops with docker’s message when %s fails',
  async (_label: string, stoppedAt: 'info' | 'secret-ls' | 'token-ls', line: string) => {
    const tools = buildStubCredentialTools({
      op: { vaults: { cloud: {} } },
      atcKey: { installed: true, zaiKey: 'zai_fixture_key' },
      host: buildMockCredentialsHostScenario({ stoppedAt }),
    });

    const ctx = await setupTest({ run: tools.run });

    expect(checkATCCredentialsPreflight(ctx.context)).rejects.toMatchObject({ exitCode: 1 });
    expect(tools.calls.at(-1)?.argv[6]).toBe(line);

    expect(ctx.err.join('')).toBe(
      'Error response from daemon: container 4f6c0a2e9d1b7c4063034ef54c9cbfed806abcb7aee937d33c352266ea8718f6 is not running\n',
    );
  },
);

test('it stops with op’s message when op item list fails', async () => {
  const tools = buildStubCredentialTools({
    op: { vaults: { cloud: {} }, failAt: 'item-list' },
    atcKey: { installed: true, zaiKey: 'zai_fixture_key' },
    host: buildMockCredentialsHostScenario(),
  });

  const ctx = await setupTest({ run: tools.run });

  expect(checkATCCredentialsPreflight(ctx.context)).rejects.toMatchObject({ exitCode: 1 });
  expect(tools.calls.at(-1)?.argv.slice(0, 3)).toStrictEqual(['op', 'item', 'list']);
  expect(ctx.err.join('')).toStartWith('[ERROR] 2026/10/07 12:00:00 (429) Too Many Requests');
});

test('it stops with install’s message when the host cannot create the secrets directory', async () => {
  const tools = buildStubCredentialTools({
    op: { vaults: { cloud: {} } },
    atcKey: { installed: true, zaiKey: 'zai_fixture_key' },
    host: buildMockCredentialsHostScenario({
      installError:
        "install: cannot create directory '/var/lib/atc-daemon-secrets': Read-only file system",
    }),
  });

  const ctx = await setupTest({ run: tools.run });

  expect(checkATCCredentialsPreflight(ctx.context)).rejects.toMatchObject({ exitCode: 1 });
  expect(ctx.out.join('')).toBe('\n== preflight\n');

  expect(ctx.err.join('')).toBe(
    "install: cannot create directory '/var/lib/atc-daemon-secrets': Read-only file system\n",
  );
});
