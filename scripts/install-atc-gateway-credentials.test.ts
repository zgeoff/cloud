import { expect, test } from 'bun:test';
import { installATCGatewayCredentials } from './install-atc-gateway-credentials.ts';
import { readHostScript } from './read-host-script.ts';
import { buildMockCredentialsHostScenario } from './test-utils/build-mock-credentials-host-scenario.ts';
import { buildStubCredentialTools } from './test-utils/build-stub-credential-tools.ts';

async function setupTest() {
  const out: string[] = [];
  const err: string[] = [];

  const writeScript = await readHostScript('write-atc-gateway-token.sh');
  const mintScript = await readHostScript('mint-atc-imp-token.sh');

  return {
    out,
    err,
    writeScript: writeScript.toString(),
    mintScript: mintScript.toString(),
    printOut: (text: string) => {
      out.push(text);
    },
    printErr: (text: string) => {
      err.push(text);
    },
  };
}

test('it skips every step and exits 0 when all three credentials exist and match', async () => {
  const ctx = await setupTest();

  const tools = buildStubCredentialTools({
    op: { vaults: { cloud: { 'atc-daemon-token': 'fixture-bearer' } } },
    atcKey: { installed: true, zaiKey: 'zai_fixture_key' },
    host: buildMockCredentialsHostScenario(),
  });

  const exitCode = await installATCGatewayCredentials({
    run: tools.run,
    env: { OP_SERVICE_ACCOUNT_TOKEN: 'ops_fixture_env' },
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(0);
  expect(ctx.err.join('')).toBe('');

  expect(ctx.out.join('')).toBe(`
== preflight
ok: 1Password vault cloud, atc-key, ssh root@geoffcloud, impd grantableTokens, /var/lib/atc-daemon-secrets

== 1/3 impd secret glm (api.z.ai, authorization: Bearer)
skip: glm exists with the expected rules

== 2/3 daemon bearer: 1Password cloud/atc-daemon-token and root@geoffcloud:/var/lib/atc-daemon-secrets/gateway-token
skip: both exist and match

== 3/3 impd token atc-cloud (manage, harness-*, grantable glm) to root@geoffcloud:/var/lib/atc-daemon-secrets/imp-token
skip: both exist, atc-cloud has the expected limits, and the file authenticates as it

== check
{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[]}
{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"grantable":["glm"]}
/var/lib/atc-daemon-secrets root 700 4096 bytes
/var/lib/atc-daemon-secrets/gateway-token root 400 15 bytes
/var/lib/atc-daemon-secrets/imp-token root 400 18 bytes
`);
});

test('it installs all three and keeps every secret out of every argv, sending each on stdin', async () => {
  const ctx = await setupTest();

  const tools = buildStubCredentialTools({
    op: { vaults: { cloud: {} } },
    atcKey: { installed: true, zaiKey: 'zai_fixture_key' },
    host: buildMockCredentialsHostScenario({
      secrets: [],
      tokens: [],
      files: {},
      minted: 'imp_fixture_minted_token\n',
    }),
  });

  const exitCode = await installATCGatewayCredentials({
    run: tools.run,
    env: { OP_SERVICE_ACCOUNT_TOKEN: 'ops_fixture_env' },
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  const bearer = tools.op.vaults['cloud']?.['atc-daemon-token'] ?? '';
  const secrets = ['zai_fixture_key', bearer, 'ops_fixture_env', 'imp_fixture_minted_token'];

  expect(exitCode).toBe(0);
  expect(bearer).toMatch(/^[\w-]{64}$/u);

  expect(
    tools.calls.filter((call) => secrets.some((secret) => call.argv.join('\0').includes(secret))),
  ).toStrictEqual([]);

  expect(tools.calls.filter((call) => call.stdin !== '').map((call) => call.stdin)).toStrictEqual([
    'zai_fixture_key\n',
    expect.toInclude(`"value":"${bearer}"`),
    `${ctx.writeScript}${bearer}\n`,
    ctx.mintScript,
  ]);
});

test('it hands op the service account token in its environment alone', async () => {
  const ctx = await setupTest();

  const tools = buildStubCredentialTools({
    op: { vaults: { cloud: {} } },
    atcKey: { installed: true, zaiKey: 'zai_fixture_key' },
    host: buildMockCredentialsHostScenario({ secrets: [], tokens: [], files: {} }),
  });

  await installATCGatewayCredentials({
    run: tools.run,
    env: { OP_SERVICE_ACCOUNT_TOKEN: 'ops_fixture_env' },
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(tools.op.tokensSeen).toSatisfyAll(
    (token: string | undefined) => token === 'ops_fixture_env',
  );

  expect(
    tools.calls.filter((call) => call.argv[0] !== 'op' && call.options.env !== undefined),
  ).toStrictEqual([]);
});

test('it prints no secret on stdout or stderr', async () => {
  const ctx = await setupTest();

  const tools = buildStubCredentialTools({
    op: { vaults: { cloud: {} } },
    atcKey: { installed: true, zaiKey: 'zai_fixture_key' },
    host: buildMockCredentialsHostScenario({
      secrets: [],
      tokens: [],
      files: {},
      minted: 'imp_fixture_minted_token\n',
    }),
  });

  await installATCGatewayCredentials({
    run: tools.run,
    env: { OP_SERVICE_ACCOUNT_TOKEN: 'ops_fixture_env' },
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  const bearer = tools.op.vaults['cloud']?.['atc-daemon-token'] ?? '';
  const printed = ctx.out.join('') + ctx.err.join('');
  const secrets = ['zai_fixture_key', bearer, 'ops_fixture_env', 'imp_fixture_minted_token'];

  expect(secrets.filter((secret) => printed.includes(secret))).toStrictEqual([]);
});

test('it stops at the first failing step with that step’s exit code and message', async () => {
  const ctx = await setupTest();

  const tools = buildStubCredentialTools({
    op: { vaults: { cloud: {} } },
    atcKey: { installed: true, zaiKey: 'zai_fixture_key' },
    host: buildMockCredentialsHostScenario({ info: { features: {} } }),
  });

  const exitCode = await installATCGatewayCredentials({
    run: tools.run,
    env: { OP_SERVICE_ACCOUNT_TOKEN: 'ops_fixture_env' },
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);
  expect(ctx.out.join('')).toBe('\n== preflight\n');
  expect(ctx.err.join('')).toBe('impd lacks grantableTokens; nothing changed\n');
});
