import { expect, mock, test } from 'bun:test';
import { server } from './mocks/node.ts';
import { runSandboxImageAdd } from './run-sandbox-image-add.ts';
import { buildStubRunner } from './test-utils/build-stub-runner.ts';
import { startStubImpdImages } from './test-utils/start-stub-impd-images.ts';

function setupTest() {
  const printOut = mock<(text: string) => void>();
  const printErr = mock<(text: string) => void>();

  return { printOut, printErr };
}

test('it adds each manifest image that impd lacks, skips one it holds, and never prints the token', async () => {
  const ctx = setupTest();

  const impd = startStubImpdImages({
    url: 'https://impd.test',
    token: 'nixie-impd-token-for-tests',
    images: [
      {
        name: 'nixie-fetch-77aa88bb99cc',
        ref: 'ghcr.io/zgeoff/nixie-fetch@sha256:77aa88bb99cc00dd11ee22ff33004455667788990011223344556677889900aa',
        digest: 'sha256:77aa88bb99cc00dd11ee22ff33004455667788990011223344556677889900aa',
      },
    ],
  });

  server.use(...impd.handlers);

  const runner = buildStubRunner(
    (call) => (call.argv[0] === 'sops' ? { stdout: 'nixie-impd-token-for-tests' } : undefined),
    (call) =>
      call.argv.join(' ') === 'nixie sandbox-manifest'
        ? {
            stdout: JSON.stringify({
              conversation: {
                name: 'nixie-conversation-5c0ffee0aa11',
                ref: 'ghcr.io/zgeoff/nixie-conversation@sha256:5c0ffee0aa11bb22cc33dd44ee55ff6600112233445566778899aabbccddeeff',
              },
              fetch: {
                name: 'nixie-fetch-77aa88bb99cc',
                ref: 'ghcr.io/zgeoff/nixie-fetch@sha256:77aa88bb99cc00dd11ee22ff33004455667788990011223344556677889900aa',
              },
            }),
          }
        : undefined,
  );

  const exitCode = await runSandboxImageAdd({
    env: { IMPD_URL: 'https://impd.test', NIXIE_SECRETS_FILE: '/etc/nixie/secrets/secrets.yaml' },
    run: runner.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(0);

  expect(impd.calls).toStrictEqual([
    'images.list',
    'images.add nixie-conversation-5c0ffee0aa11 ghcr.io/zgeoff/nixie-conversation@sha256:5c0ffee0aa11bb22cc33dd44ee55ff6600112233445566778899aabbccddeeff',
  ]);

  expect(runner.calls.map((call) => call.argv)).toStrictEqual([
    ['sops', 'decrypt', '--extract', '["impd_token"]', '/etc/nixie/secrets/secrets.yaml'],
    ['nixie', 'sandbox-manifest'],
  ]);

  expect(ctx.printOut.mock.calls).toStrictEqual([
    ['held nixie-fetch-77aa88bb99cc\n'],
    ['added nixie-conversation-5c0ffee0aa11\n'],
  ]);

  expect(ctx.printErr).not.toHaveBeenCalled();
});

test('it exits 1 and names the image when impd refuses an add', async () => {
  const ctx = setupTest();

  const impd = startStubImpdImages({
    url: 'https://impd.test',
    token: 'nixie-impd-token-for-tests',
    images: [],
    refusedRefs: [
      'ghcr.io/zgeoff/nixie-conversation@sha256:5c0ffee0aa11bb22cc33dd44ee55ff6600112233445566778899aabbccddeeff',
    ],
  });

  server.use(...impd.handlers);

  const runner = buildStubRunner(
    (call) => (call.argv[0] === 'sops' ? { stdout: 'nixie-impd-token-for-tests\n' } : undefined),
    (call) =>
      call.argv.join(' ') === 'nixie sandbox-manifest'
        ? {
            stdout: JSON.stringify({
              conversation: {
                name: 'nixie-conversation-5c0ffee0aa11',
                ref: 'ghcr.io/zgeoff/nixie-conversation@sha256:5c0ffee0aa11bb22cc33dd44ee55ff6600112233445566778899aabbccddeeff',
              },
              fetch: {
                name: 'nixie-fetch-77aa88bb99cc',
                ref: 'ghcr.io/zgeoff/nixie-fetch@sha256:77aa88bb99cc00dd11ee22ff33004455667788990011223344556677889900aa',
              },
            }),
          }
        : undefined,
  );

  const exitCode = await runSandboxImageAdd({
    env: { IMPD_URL: 'https://impd.test', NIXIE_SECRETS_FILE: '/etc/nixie/secrets/secrets.yaml' },
    run: runner.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);

  expect(impd.calls).toStrictEqual([
    'images.list',
    'images.add nixie-conversation-5c0ffee0aa11 ghcr.io/zgeoff/nixie-conversation@sha256:5c0ffee0aa11bb22cc33dd44ee55ff6600112233445566778899aabbccddeeff',
  ]);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    [
      'run-sandbox-image-add: impd did not add the image nixie-conversation-5c0ffee0aa11 from ghcr.io/zgeoff/nixie-conversation@sha256:5c0ffee0aa11bb22cc33dd44ee55ff6600112233445566778899aabbccddeeff: token nixie may add only images whose ref starts with ghcr.io/zgeoff/nixie-\n',
    ],
  ]);

  expect(ctx.printOut).not.toHaveBeenCalled();
});

test('it exits 1 with no add when impd holds a manifest name at another digest', async () => {
  const ctx = setupTest();

  const impd = startStubImpdImages({
    url: 'https://impd.test',
    token: 'nixie-impd-token-for-tests',
    images: [
      {
        name: 'nixie-fetch-77aa88bb99cc',
        ref: 'ghcr.io/zgeoff/nixie-fetch@sha256:0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f',
        digest: 'sha256:0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f',
      },
    ],
  });

  server.use(...impd.handlers);

  const runner = buildStubRunner(
    (call) => (call.argv[0] === 'sops' ? { stdout: 'nixie-impd-token-for-tests' } : undefined),
    (call) =>
      call.argv.join(' ') === 'nixie sandbox-manifest'
        ? {
            stdout: JSON.stringify({
              conversation: {
                name: 'nixie-conversation-5c0ffee0aa11',
                ref: 'ghcr.io/zgeoff/nixie-conversation@sha256:5c0ffee0aa11bb22cc33dd44ee55ff6600112233445566778899aabbccddeeff',
              },
              fetch: {
                name: 'nixie-fetch-77aa88bb99cc',
                ref: 'ghcr.io/zgeoff/nixie-fetch@sha256:77aa88bb99cc00dd11ee22ff33004455667788990011223344556677889900aa',
              },
            }),
          }
        : undefined,
  );

  const exitCode = await runSandboxImageAdd({
    env: { IMPD_URL: 'https://impd.test', NIXIE_SECRETS_FILE: '/etc/nixie/secrets/secrets.yaml' },
    run: runner.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);
  expect(impd.calls).toStrictEqual(['images.list']);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    [
      'impd holds the image nixie-fetch-77aa88bb99cc at sha256:0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f from ghcr.io/zgeoff/nixie-fetch@sha256:0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f, not sha256:77aa88bb99cc00dd11ee22ff33004455667788990011223344556677889900aa\n',
    ],
  ]);
});

test('it exits 1 with no impd call when sops cannot read the token', async () => {
  const ctx = setupTest();

  const impd = startStubImpdImages({
    url: 'https://impd.test',
    token: 'nixie-impd-token-for-tests',
    images: [],
  });

  server.use(...impd.handlers);

  // sops 3.x's answer to a file that no age identity it holds decrypts
  const runner = buildStubRunner((call) =>
    call.argv[0] === 'sops'
      ? { exitCode: 128, stderr: 'Failed to get the data key required to decrypt the SOPS file.\n' }
      : undefined,
  );

  const exitCode = await runSandboxImageAdd({
    env: { IMPD_URL: 'https://impd.test', NIXIE_SECRETS_FILE: '/etc/nixie/secrets/secrets.yaml' },
    run: runner.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);
  expect(impd.calls).toStrictEqual([]);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    [
      'run-sandbox-image-add: sops could not read impd_token (exit 128): Failed to get the data key required to decrypt the SOPS file.\n',
    ],
  ]);
});

test("it exits 1 with no impd call when the manifest holds a ref outside nixie's registry path", async () => {
  const ctx = setupTest();

  const impd = startStubImpdImages({
    url: 'https://impd.test',
    token: 'nixie-impd-token-for-tests',
    images: [],
  });

  server.use(...impd.handlers);

  const runner = buildStubRunner(
    (call) => (call.argv[0] === 'sops' ? { stdout: 'nixie-impd-token-for-tests' } : undefined),
    (call) =>
      call.argv.join(' ') === 'nixie sandbox-manifest'
        ? {
            stdout: JSON.stringify({
              conversation: {
                name: 'nixie-conversation-5c0ffee0aa11',
                ref: 'docker.io/library/nixie-conversation@sha256:5c0ffee0aa11bb22cc33dd44ee55ff6600112233445566778899aabbccddeeff',
              },
            }),
          }
        : undefined,
  );

  const exitCode = await runSandboxImageAdd({
    env: { IMPD_URL: 'https://impd.test', NIXIE_SECRETS_FILE: '/etc/nixie/secrets/secrets.yaml' },
    run: runner.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);
  expect(impd.calls).toStrictEqual([]);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    [
      "run-sandbox-image-add: nixie's sandbox manifest: ✖ Invalid string: must match pattern /^ghcr\\.io\\/zgeoff\\/nixie-[a-z0-9-]+@(?<digest>sha256:[0-9a-f]{64})$/u\n  → at conversation.ref\n",
    ],
  ]);
});

test('it exits 2 when the Job leaves out its environment', async () => {
  const ctx = setupTest();
  const runner = buildStubRunner();

  const exitCode = await runSandboxImageAdd({
    env: { IMPD_URL: 'https://impd.test' },
    run: runner.run,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(2);
  expect(runner.calls).toStrictEqual([]);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    ['run-sandbox-image-add: IMPD_URL and NIXIE_SECRETS_FILE must be set\n'],
  ]);
});
