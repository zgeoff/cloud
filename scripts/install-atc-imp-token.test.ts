import { expect, test } from 'bun:test';
import { installATCImpToken } from './install-atc-imp-token.ts';
import { loadATCCredentialsContext } from './load-atc-credentials-context.ts';
import { readHostScript } from './read-host-script.ts';
import type { Runner } from './run-process.ts';
import { buildMockCredentialsHostScenario } from './test-utils/build-mock-credentials-host-scenario.ts';
import { buildMockImpToken } from './test-utils/build-mock-imp-token.ts';
import { buildStubCredentialTools } from './test-utils/build-stub-credential-tools.ts';

interface SetupConfig {
  readonly run: Runner;
  readonly env: Readonly<Record<string, string>>;
}

async function setupTest(config: SetupConfig) {
  const out: string[] = [];
  const err: string[] = [];

  const context = await loadATCCredentialsContext({
    run: config.run,
    env: config.env,
    printOut: (text) => {
      out.push(text);
    },
    printErr: (text) => {
      err.push(text);
    },
  });

  const checkScript = await readHostScript('check-atc-imp-token.sh');
  const mintScript = await readHostScript('mint-atc-imp-token.sh');

  return {
    context,
    out,
    err,
    checkScript: checkScript.toString(),
    mintScript: mintScript.toString(),
  };
}

test('it skips a token with the expected limits whose saved file authenticates as it', async () => {
  const tools = buildStubCredentialTools({
    op: { vaults: {} },
    atcKey: { installed: true, zaiKey: 'zai_fixture_key' },
    host: buildMockCredentialsHostScenario(),
  });

  const ctx = await setupTest({
    run: tools.run,
    env: { OP_SERVICE_ACCOUNT_TOKEN: 'ops_fixture_env' },
  });

  await installATCImpToken(ctx.context, {
    secrets: [],
    tokens: [buildMockImpToken()],
    hasItem: false,
    hostFiles: ['imp-token'],
  });

  expect(ctx.out.join('')).toBe(
    '\n== 3/3 impd token atc-cloud (manage, harness-*, grantable glm,claude-setup-token,github-imp-agents,linear-imp-agents,op-connect) to root@geoffcloud:/var/lib/atc-daemon-secrets/imp-token\nskip: both exist, atc-cloud has the expected limits, and the file authenticates as it\n',
  );

  expect(tools.calls.map((call) => [call.argv.join(' '), call.stdin])).toStrictEqual([
    [
      "ssh -o BatchMode=yes root@geoffcloud bash -s -- '/var/lib/atc-daemon-secrets' '7070'",
      ctx.checkScript,
    ],
  ]);
});

test('it checks the saved file against the impd port and directory the environment names', async () => {
  const tools = buildStubCredentialTools({
    op: { vaults: {} },
    atcKey: { installed: true, zaiKey: 'zai_fixture_key' },
    host: buildMockCredentialsHostScenario({
      host: 'root@canary',
      dir: '/srv/atc secrets',
      impdPort: '7171',
    }),
  });

  const ctx = await setupTest({
    run: tools.run,
    env: {
      OP_SERVICE_ACCOUNT_TOKEN: 'ops_fixture_env',
      ATC_CREDENTIALS_HOST: 'root@canary',
      ATC_CREDENTIALS_DIR: '/srv/atc secrets',
      ATC_IMPD_PORT: '7171',
    },
  });

  await installATCImpToken(ctx.context, {
    secrets: [],
    tokens: [buildMockImpToken()],
    hasItem: false,
    hostFiles: ['imp-token'],
  });

  expect(tools.calls.map((call) => call.argv)).toStrictEqual([
    ['ssh', '-o', 'BatchMode=yes', 'root@canary', "bash -s -- '/srv/atc secrets' '7171'"],
  ]);
});

test.each([
  ['a file atc cannot use', { exitCode: 121 }],
  ['impd’s 401 for an unknown token', { stdout: '{"error":"unauthorized"}\n401' }],
  ['another token', { stdout: '{"json":{"kind":"token","name":"atc-other"}}\n200' }],
])(
  'it rejects a saved token the host check reads as %s',
  async (_label: string, tokenCheck: object) => {
    const tools = buildStubCredentialTools({
      op: { vaults: {} },
      atcKey: { installed: true, zaiKey: 'zai_fixture_key' },
      host: buildMockCredentialsHostScenario({ tokenCheck }),
    });

    const ctx = await setupTest({
      run: tools.run,
      env: { OP_SERVICE_ACCOUNT_TOKEN: 'ops_fixture_env' },
    });

    expect(
      installATCImpToken(ctx.context, {
        secrets: [],
        tokens: [buildMockImpToken()],
        hasItem: false,
        hostFiles: ['imp-token'],
      }),
    ).rejects.toMatchObject({
      exitCode: 1,
      message: `/var/lib/atc-daemon-secrets/imp-token does not authenticate to impd as the token atc-cloud (empty, more
than one line, stale or another token). impd shows a token once, so remove
/var/lib/atc-daemon-secrets/imp-token and run 'impz token rm atc-cloud' in imp-host, then rerun to mint
a new one`,
    });
  },
);

test.each([
  [
    'impd’s 500',
    { stdout: '{"json":{}}\n500' },
    "impd answered HTTP 500, so /var/lib/atc-daemon-secrets/imp-token is unchecked; nothing changed.\nCheck impd on the host's 127.0.0.1:7070, then rerun",
  ],
  [
    'exit 120 for a file it cannot read',
    { exitCode: 120 },
    'the saved token is not a readable regular file on the host, so /var/lib/atc-daemon-secrets/imp-token is unchecked; nothing changed.\nCheck /var/lib/atc-daemon-secrets/imp-token on the host, then rerun',
  ],
])(
  'it leaves the saved token unchecked when the host check answers %s',
  async (_label: string, tokenCheck: object, message: string) => {
    const tools = buildStubCredentialTools({
      op: { vaults: {} },
      atcKey: { installed: true, zaiKey: 'zai_fixture_key' },
      host: buildMockCredentialsHostScenario({ tokenCheck }),
    });

    const ctx = await setupTest({
      run: tools.run,
      env: { OP_SERVICE_ACCOUNT_TOKEN: 'ops_fixture_env' },
    });

    expect(
      installATCImpToken(ctx.context, {
        secrets: [],
        tokens: [buildMockImpToken()],
        hasItem: false,
        hostFiles: ['imp-token'],
      }),
    ).rejects.toMatchObject({ exitCode: 1, message });
  },
);

test('it passes the host check’s stderr through, before its verdict', async () => {
  const tools = buildStubCredentialTools({
    op: { vaults: {} },
    atcKey: { installed: true, zaiKey: 'zai_fixture_key' },
    host: buildMockCredentialsHostScenario({
      tokenCheck: { exitCode: 255, stderr: 'Connection to geoffcloud closed by remote host.\r\n' },
    }),
  });

  const ctx = await setupTest({
    run: tools.run,
    env: { OP_SERVICE_ACCOUNT_TOKEN: 'ops_fixture_env' },
  });

  expect(
    installATCImpToken(ctx.context, {
      secrets: [],
      tokens: [buildMockImpToken()],
      hasItem: false,
      hostFiles: ['imp-token'],
    }),
  ).rejects.toMatchObject({ exitCode: 1 });

  expect(ctx.err.join('')).toBe('Connection to geoffcloud closed by remote host.\r\n');
});

test.each([
  ['another scope', buildMockImpToken({ scope: 'admin' })],
  ['other imps', buildMockImpToken({ imps: ['*'] })],
  ['another grantable list', buildMockImpToken({ grantable: [] })],
])(
  'it stops without a check when atc-cloud exists with %s',
  async (_label: string, token: unknown) => {
    const tools = buildStubCredentialTools({
      op: { vaults: {} },
      atcKey: { installed: true, zaiKey: 'zai_fixture_key' },
      host: buildMockCredentialsHostScenario(),
    });

    const ctx = await setupTest({
      run: tools.run,
      env: { OP_SERVICE_ACCOUNT_TOKEN: 'ops_fixture_env' },
    });

    expect(
      installATCImpToken(ctx.context, {
        secrets: [],
        tokens: [token],
        hasItem: false,
        hostFiles: ['imp-token'],
      }),
    ).rejects.toMatchObject({
      exitCode: 1,
      message:
        "atc-cloud exists with another scope, imps or grantable list; fix it by hand, such as with\n'impz token set atc-cloud --grantable glm,claude-setup-token,github-imp-agents,linear-imp-agents,op-connect' in imp-host, then rerun",
    });

    expect(tools.calls).toStrictEqual([]);
  },
);

test.each([
  ['the atc-cloud token', [buildMockImpToken()], []],
  ['the saved token file', [], ['imp-token']],
])(
  'it stops without a mint when only %s exists',
  async (_label: string, tokens: readonly unknown[], hostFiles: readonly string[]) => {
    const tools = buildStubCredentialTools({
      op: { vaults: {} },
      atcKey: { installed: true, zaiKey: 'zai_fixture_key' },
      host: buildMockCredentialsHostScenario(),
    });

    const ctx = await setupTest({
      run: tools.run,
      env: { OP_SERVICE_ACCOUNT_TOKEN: 'ops_fixture_env' },
    });

    expect(
      installATCImpToken(ctx.context, { secrets: [], tokens, hasItem: false, hostFiles }),
    ).rejects.toMatchObject({
      exitCode: 1,
      message: `only one exists (token: ${tokens.length > 0}, host file: ${hostFiles.length > 0}). impd shows a token once,\nso run 'impz token rm atc-cloud' in imp-host and remove /var/lib/atc-daemon-secrets/imp-token, then rerun`,
    });

    expect(tools.calls).toStrictEqual([]);
  },
);

test('it mints atc-cloud on the host with the mint script on stdin when neither exists', async () => {
  const tools = buildStubCredentialTools({
    op: { vaults: {} },
    atcKey: { installed: true, zaiKey: 'zai_fixture_key' },
    host: buildMockCredentialsHostScenario({
      tokens: [],
      files: {},
      minted: 'imp_fixture_minted_token\n',
    }),
  });

  const ctx = await setupTest({
    run: tools.run,
    env: { OP_SERVICE_ACCOUNT_TOKEN: 'ops_fixture_env' },
  });

  await installATCImpToken(ctx.context, { secrets: [], tokens: [], hasItem: false, hostFiles: [] });

  expect(tools.host.files).toStrictEqual({
    'imp-token': { content: 'imp_fixture_minted_token\n', mode: '400' },
  });

  expect(ctx.err.join('')).toBe(
    'impz: token atc-cloud made; impd shows its secret only this once\n',
  );

  expect(tools.calls.map((call) => [call.argv.join(' '), call.stdin])).toStrictEqual([
    [
      "ssh -o BatchMode=yes root@geoffcloud bash -s -- '/var/lib/atc-daemon-secrets'",
      ctx.mintScript,
    ],
  ]);
});

test.each([
  ['the mint prints more than one line', { minted: 'imp_fixture_minted_token\nsecond line\n' }],
  ['impz token new fails', { mintError: 'impz: CONFLICT: token atc-cloud exists' }],
])('it saves no token when %s', async (_label: string, fault: object) => {
  const tools = buildStubCredentialTools({
    op: { vaults: {} },
    atcKey: { installed: true, zaiKey: 'zai_fixture_key' },
    host: buildMockCredentialsHostScenario({ tokens: [], files: {}, ...fault }),
  });

  const ctx = await setupTest({
    run: tools.run,
    env: { OP_SERVICE_ACCOUNT_TOKEN: 'ops_fixture_env' },
  });

  expect(
    installATCImpToken(ctx.context, { secrets: [], tokens: [], hasItem: false, hostFiles: [] }),
  ).rejects.toMatchObject({ exitCode: 1 });

  expect(tools.host.files).toStrictEqual({});
});
