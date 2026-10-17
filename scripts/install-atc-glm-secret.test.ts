import { expect, test } from 'bun:test';
import { installATCGLMSecret } from './install-atc-glm-secret.ts';
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

test('it skips a glm with the expected rules', async () => {
  const tools = buildStubCredentialTools({
    op: { vaults: { cloud: {} } },
    atcKey: { installed: true, zaiKey: 'zai_fixture_key' },
    host: buildMockCredentialsHostScenario(),
  });

  const ctx = await setupTest({ run: tools.run });

  await installATCGLMSecret(ctx.context, {
    secrets: [buildMockImpSecret()],
    tokens: [],
    hasItem: false,
    hostFiles: [],
  });

  expect(ctx.out.join('')).toBe(
    '\n== 1/3 impd secret glm (api.z.ai, authorization: Bearer)\nskip: glm exists with the expected rules\n',
  );

  expect(tools.calls).toStrictEqual([]);
});

test('it accepts glm rules that hold the same fields in another order', async () => {
  const tools = buildStubCredentialTools({
    op: { vaults: { cloud: {} } },
    atcKey: { installed: true, zaiKey: 'zai_fixture_key' },
    host: buildMockCredentialsHostScenario(),
  });

  const ctx = await setupTest({ run: tools.run });

  await installATCGLMSecret(ctx.context, {
    secrets: [
      buildMockImpSecret({
        rules: [{ scheme: 'bearer', header: 'authorization', host: 'api.z.ai' }],
      }),
    ],
    tokens: [],
    hasItem: false,
    hostFiles: [],
  });

  expect(ctx.out.join('')).toEndWith('skip: glm exists with the expected rules\n');
});

test.each([
  [
    'other rules',
    buildMockImpSecret({ rules: [{ host: 'api.z.ai', header: 'x-api-key', scheme: 'bearer' }] }),
  ],
  ['another kind', buildMockImpSecret({ kind: 'anthropic' })],
])('it stops when glm exists with %s', async (_label: string, glm: unknown) => {
  const tools = buildStubCredentialTools({
    op: { vaults: { cloud: {} } },
    atcKey: { installed: true, zaiKey: 'zai_fixture_key' },
    host: buildMockCredentialsHostScenario(),
  });

  const ctx = await setupTest({ run: tools.run });

  expect(
    installATCGLMSecret(ctx.context, { secrets: [glm], tokens: [], hasItem: false, hostFiles: [] }),
  ).rejects.toMatchObject({
    exitCode: 1,
    message: 'glm exists with other rules; fix it by hand, then rerun',
  });

  expect(tools.calls).toStrictEqual([]);
});

test('it adds glm with the z.ai key on imp’s stdin, never its argv', async () => {
  const tools = buildStubCredentialTools({
    op: { vaults: { cloud: {} } },
    atcKey: { installed: true, zaiKey: 'zai_fixture_key' },
    host: buildMockCredentialsHostScenario({ secrets: [] }),
  });

  const ctx = await setupTest({ run: tools.run });

  await installATCGLMSecret(ctx.context, {
    secrets: [],
    tokens: [],
    hasItem: false,
    hostFiles: [],
  });

  expect(tools.host.secretValues).toStrictEqual({ glm: 'zai_fixture_key' });

  expect(tools.calls.map((call) => [call.argv.join(' '), call.stdin])).toStrictEqual([
    ['atc-key zai', ''],
    [
      "ssh -o BatchMode=yes -o ConnectTimeout=15 root@geoffcloud 'docker' 'exec' '-i' 'imp-host' 'impz' 'secret' 'add' 'glm' '--kind' 'custom' '--hosts' 'api.z.ai' '--header' 'authorization' '--scheme' 'bearer' '--json'",
      'zai_fixture_key\n',
    ],
  ]);
});

test('it prints the added secret’s name, kind and rules', async () => {
  const tools = buildStubCredentialTools({
    op: { vaults: { cloud: {} } },
    atcKey: { installed: true, zaiKey: 'zai_fixture_key' },
    host: buildMockCredentialsHostScenario({ secrets: [] }),
  });

  const ctx = await setupTest({ run: tools.run });

  await installATCGLMSecret(ctx.context, {
    secrets: [],
    tokens: [],
    hasItem: false,
    hostFiles: [],
  });

  expect(ctx.out.join('')).toBe(
    '\n== 1/3 impd secret glm (api.z.ai, authorization: Bearer)\n{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}]}\n',
  );
});

test('it stops before impd when atc-key prints no z.ai key', async () => {
  const tools = buildStubCredentialTools({
    op: { vaults: { cloud: {} } },
    atcKey: { installed: true, zaiKey: '' },
    host: buildMockCredentialsHostScenario({ secrets: [] }),
  });

  const ctx = await setupTest({ run: tools.run });

  expect(
    installATCGLMSecret(ctx.context, { secrets: [], tokens: [], hasItem: false, hostFiles: [] }),
  ).rejects.toMatchObject({ exitCode: 1, message: 'atc-key zai printed nothing; nothing changed' });

  expect(tools.calls.map((call) => call.argv[0])).toStrictEqual(['atc-key']);
});

test('it stops with imp’s exit code and message when impd rejects the secret', async () => {
  const tools = buildStubCredentialTools({
    op: { vaults: { cloud: {} } },
    atcKey: { installed: true, zaiKey: 'zai_fixture_key' },
    host: buildMockCredentialsHostScenario({
      secrets: [],
      secretAddError: 'imp: BAD_REQUEST: rule host api.z.ai is not allowed',
    }),
  });

  const ctx = await setupTest({ run: tools.run });

  expect(
    installATCGLMSecret(ctx.context, { secrets: [], tokens: [], hasItem: false, hostFiles: [] }),
  ).rejects.toMatchObject({ exitCode: 2 });

  expect(ctx.err.join('')).toBe('imp: BAD_REQUEST: rule host api.z.ai is not allowed\n');
});
