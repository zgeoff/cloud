import { expect, test } from 'bun:test';
import { loadATCCredentialsContext } from './load-atc-credentials-context.ts';
import { printATCCredentials } from './print-atc-credentials.ts';
import type { Runner } from './run-process.ts';
import { buildMockCredentialsHostScenario } from './test-utils/build-mock-credentials-host-scenario.ts';
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

test('it prints glm’s and atc-cloud’s names and limits, and each file’s owner, mode and size', async () => {
  const tools = buildStubCredentialTools({
    op: { vaults: {} },
    atcKey: { installed: true, zaiKey: 'zai_fixture_key' },
    host: buildMockCredentialsHostScenario(),
  });

  const ctx = await setupTest({ run: tools.run });

  await printATCCredentials(ctx.context);

  expect(ctx.out.join('')).toBe(`
== check
{"name":"glm","kind":"custom","rules":[{"host":"api.z.ai","header":"authorization","scheme":"bearer"}],"imps":[]}
{"name":"atc-cloud","scope":"manage","imps":["harness-*"],"grantable":["glm"]}
/var/lib/atc-daemon-secrets root 700 4096 bytes
/var/lib/atc-daemon-secrets/gateway-token root 400 15 bytes
/var/lib/atc-daemon-secrets/imp-token root 400 18 bytes
`);
});

test('it fails with stat’s message when a saved file is gone', async () => {
  const tools = buildStubCredentialTools({
    op: { vaults: {} },
    atcKey: { installed: true, zaiKey: 'zai_fixture_key' },
    host: buildMockCredentialsHostScenario({ goneBeforeStat: ['gateway-token'] }),
  });

  const ctx = await setupTest({ run: tools.run });

  expect(printATCCredentials(ctx.context)).rejects.toMatchObject({ exitCode: 1 });

  expect(ctx.err.join('')).toBe(
    "stat: cannot statx '/var/lib/atc-daemon-secrets/gateway-token': No such file or directory\n",
  );
});
