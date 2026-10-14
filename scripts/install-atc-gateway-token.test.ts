import { expect, test } from 'bun:test';
import { installATCGatewayToken } from './install-atc-gateway-token.ts';
import { loadATCCredentialsContext } from './load-atc-credentials-context.ts';
import { readHostScript } from './read-host-script.ts';
import type { Runner } from './run-process.ts';
import { buildMockCredentialsHostScenario } from './test-utils/build-mock-credentials-host-scenario.ts';
import { buildStubCredentialTools } from './test-utils/build-stub-credential-tools.ts';
import type { StubCredentialsHostScenario } from './test-utils/build-stub-credentials-host.ts';
import type { StubOpScenario } from './test-utils/build-stub-op.ts';

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

  const writeScript = await readHostScript('write-atc-gateway-token.sh');

  return { context, out, err, writeScript: writeScript.toString() };
}

test('it skips a 1Password item and a host file that match', async () => {
  const tools = buildStubCredentialTools({
    op: { vaults: { cloud: { 'atc-daemon-token': 'fixture-bearer' } } },
    atcKey: { installed: true, zaiKey: 'zai_fixture_key' },
    host: buildMockCredentialsHostScenario(),
  });

  const ctx = await setupTest({ run: tools.run });

  await installATCGatewayToken(ctx.context, {
    secrets: [],
    tokens: [],
    hasItem: true,
    hostFiles: ['gateway-token'],
  });

  expect(ctx.out.join('')).toBe(
    '\n== 2/3 daemon bearer: 1Password cloud/atc-daemon-token and root@geoffcloud:/var/lib/atc-daemon-secrets/gateway-token\nskip: both exist and match\n',
  );

  expect(tools.calls.map((call) => call.argv.join(' '))).toStrictEqual([
    'op read op://cloud/atc-daemon-token/credential',
    "ssh -o BatchMode=yes root@geoffcloud sha256sum '/var/lib/atc-daemon-secrets/gateway-token'",
  ]);
});

test('it stops when the 1Password item and the host file differ', async () => {
  const tools = buildStubCredentialTools({
    op: { vaults: { cloud: { 'atc-daemon-token': 'fixture-bearer' } } },
    atcKey: { installed: true, zaiKey: 'zai_fixture_key' },
    host: buildMockCredentialsHostScenario({
      files: { 'gateway-token': { content: 'other-bearer\n', mode: '400' } },
    }),
  });

  const ctx = await setupTest({ run: tools.run });

  expect(
    installATCGatewayToken(ctx.context, {
      secrets: [],
      tokens: [],
      hasItem: true,
      hostFiles: ['gateway-token'],
    }),
  ).rejects.toMatchObject({
    exitCode: 1,
    message: 'the 1Password item and the host file differ; fix by hand, then rerun',
  });
});

test.each([
  ['the 1Password item', true, []],
  ['the host file', false, ['gateway-token']],
])(
  'it stops without a change when only %s holds the bearer',
  async (_label: string, hasItem: boolean, hostFiles: string[]) => {
    const tools = buildStubCredentialTools({
      op: { vaults: { cloud: {} } },
      atcKey: { installed: true, zaiKey: 'zai_fixture_key' },
      host: buildMockCredentialsHostScenario({ files: {} }),
    });

    const ctx = await setupTest({ run: tools.run });

    expect(
      installATCGatewayToken(ctx.context, { secrets: [], tokens: [], hasItem, hostFiles }),
    ).rejects.toMatchObject({
      exitCode: 1,
      message: `only one copy exists (item: ${hasItem}, host file: ${!hasItem}); fix by hand, then rerun`,
    });

    expect(tools.calls).toStrictEqual([]);
  },
);

test('it mints one bearer into the 1Password item and a root-only host file when neither exists', async () => {
  const tools = buildStubCredentialTools({
    op: { vaults: { cloud: {} } },
    atcKey: { installed: true, zaiKey: 'zai_fixture_key' },
    host: buildMockCredentialsHostScenario({ files: {} }),
  });

  const ctx = await setupTest({ run: tools.run });

  await installATCGatewayToken(ctx.context, {
    secrets: [],
    tokens: [],
    hasItem: false,
    hostFiles: [],
  });

  const bearer = tools.op.vaults['cloud']?.['atc-daemon-token'] ?? '';

  expect(bearer).toMatch(/^[\w-]{64}$/u);

  expect(tools.host.files).toStrictEqual({
    'gateway-token': { content: `${bearer}\n`, mode: '400' },
  });

  expect(ctx.out.join('')).toEndWith(
    '1Password: atc-daemon-token (fixture-item-id)\nok: the 1Password item and the host file match\n',
  );
});

test('it sends the bearer on stdin only: in op’s item template and after the host script', async () => {
  const tools = buildStubCredentialTools({
    op: { vaults: { cloud: {} } },
    atcKey: { installed: true, zaiKey: 'zai_fixture_key' },
    host: buildMockCredentialsHostScenario({ files: {} }),
  });

  const ctx = await setupTest({ run: tools.run });

  await installATCGatewayToken(ctx.context, {
    secrets: [],
    tokens: [],
    hasItem: false,
    hostFiles: [],
  });

  const bearer = tools.op.vaults['cloud']?.['atc-daemon-token'] ?? '';

  expect(tools.calls.map((call) => [call.argv.join(' '), call.stdin])).toStrictEqual([
    [
      'op item create --vault cloud - --format json',
      JSON.stringify({
        title: 'atc-daemon-token',
        category: 'API_CREDENTIAL',
        fields: [{ id: 'credential', type: 'CONCEALED', label: 'credential', value: bearer }],
      }),
    ],
    [
      "ssh -o BatchMode=yes root@geoffcloud bash -s -- '/var/lib/atc-daemon-secrets'",
      `${ctx.writeScript}${bearer}\n`,
    ],
    ['op read op://cloud/atc-daemon-token/credential', ''],
    [
      "ssh -o BatchMode=yes root@geoffcloud sha256sum '/var/lib/atc-daemon-secrets/gateway-token'",
      '',
    ],
  ]);
});

test('it mints a different bearer on each run', async () => {
  const first = buildStubCredentialTools({
    op: { vaults: { cloud: {} } },
    atcKey: { installed: true, zaiKey: 'zai_fixture_key' },
    host: buildMockCredentialsHostScenario({ files: {} }),
  });

  const second = buildStubCredentialTools({
    op: { vaults: { cloud: {} } },
    atcKey: { installed: true, zaiKey: 'zai_fixture_key' },
    host: buildMockCredentialsHostScenario({ files: {} }),
  });

  const firstCtx = await setupTest({ run: first.run });
  const secondCtx = await setupTest({ run: second.run });

  await installATCGatewayToken(firstCtx.context, {
    secrets: [],
    tokens: [],
    hasItem: false,
    hostFiles: [],
  });

  await installATCGatewayToken(secondCtx.context, {
    secrets: [],
    tokens: [],
    hasItem: false,
    hostFiles: [],
  });

  expect(first.op.vaults['cloud']?.['atc-daemon-token']).not.toBe(
    second.op.vaults['cloud']?.['atc-daemon-token'],
  );
});

test.each([
  ['1Password', { readValue: 'other-bearer' }, {}],
  ['the host', {}, { alterBearer: 'altered\n' }],
])(
  'it stops when the minted bearer reads back differently from %s',
  async (
    _label: string,
    opFault: Partial<StubOpScenario>,
    hostFault: Partial<StubCredentialsHostScenario>,
  ) => {
    const tools = buildStubCredentialTools({
      op: { vaults: { cloud: {} }, ...opFault },
      atcKey: { installed: true, zaiKey: 'zai_fixture_key' },
      host: buildMockCredentialsHostScenario({ files: {}, ...hostFault }),
    });

    const ctx = await setupTest({ run: tools.run });

    expect(
      installATCGatewayToken(ctx.context, {
        secrets: [],
        tokens: [],
        hasItem: false,
        hostFiles: [],
      }),
    ).rejects.toMatchObject({
      exitCode: 1,
      message: 'the copies differ; fix by hand before the gateway uses them',
    });
  },
);

test('it writes no host file when creating the 1Password item fails', async () => {
  const tools = buildStubCredentialTools({
    op: { vaults: { cloud: {} }, failAt: 'item-create' },
    atcKey: { installed: true, zaiKey: 'zai_fixture_key' },
    host: buildMockCredentialsHostScenario({ files: {} }),
  });

  const ctx = await setupTest({ run: tools.run });

  expect(
    installATCGatewayToken(ctx.context, { secrets: [], tokens: [], hasItem: false, hostFiles: [] }),
  ).rejects.toMatchObject({ exitCode: 1 });

  expect(tools.host.files).toStrictEqual({});
  expect(ctx.err.join('')).toStartWith('[ERROR] 2026/10/07 12:00:00 (429) Too Many Requests');
});

test('it stops with the item created and the host’s message when the host cannot write the bearer', async () => {
  const tools = buildStubCredentialTools({
    op: { vaults: { cloud: {} } },
    atcKey: { installed: true, zaiKey: 'zai_fixture_key' },
    host: buildMockCredentialsHostScenario({
      files: {},
      writeError:
        "mktemp: failed to create file via template '/var/lib/atc-daemon-secrets/.gateway-token.XXXXXX': Read-only file system",
    }),
  });

  const ctx = await setupTest({ run: tools.run });

  expect(
    installATCGatewayToken(ctx.context, { secrets: [], tokens: [], hasItem: false, hostFiles: [] }),
  ).rejects.toMatchObject({ exitCode: 1 });

  expect(Object.keys(tools.op.vaults['cloud'] ?? {})).toStrictEqual(['atc-daemon-token']);

  expect(ctx.err.join('')).toBe(
    "mktemp: failed to create file via template '/var/lib/atc-daemon-secrets/.gateway-token.XXXXXX': Read-only file system\n",
  );
});
