import { expect, mock, test } from 'bun:test';
import { http, passthrough } from 'msw';
import { server } from './mocks/node.ts';
import { runNixieAPICheck } from './run-nixie-api-check.ts';
import type { KubectlProxyStart } from './start-kubectl-proxy.ts';
import { buildStubRunner } from './test-utils/build-stub-runner.ts';
import { startStubNixieAPI } from './test-utils/start-stub-nixie-api.ts';

function setupTest() {
  return {
    printOut: mock<(text: string) => void>(),
    printErr: mock<(text: string) => void>(),
    stop: mock<() => Promise<void>>(() => Promise.resolve()),
  };
}

test('it checks nixie through the service proxy once the rollout finishes, then stops the proxy', async () => {
  const ctx = setupTest();

  const stub = startStubNixieAPI({
    url: 'http://127.0.0.1:41873/api/v1/namespaces/nixie/services/http:nixie:http/proxy',
    enrolCodes: [],
    sequences: [],
    keepaliveMs: null,
    closeAfterMs: null,
  });

  // kubectl's answer for a StatefulSet that rolled (pkg/polymorphichelpers/rollout_status.go)
  const runner = buildStubRunner((call) =>
    call.argv.join(' ') ===
    'kubectl --namespace nixie rollout status statefulset/nixie --timeout=600s'
      ? { stdout: 'statefulset rolling update complete 1 pods at revision nixie-7c9d5f6b8...\n' }
      : undefined,
  );

  const exitCode = await runNixieAPICheck({
    run: runner.run,
    startProxy: () =>
      Promise.resolve<KubectlProxyStart>({
        ok: true,
        proxy: { url: 'http://127.0.0.1:41873', stop: ctx.stop },
      }),
    printOut: ctx.printOut,
    printErr: ctx.printErr,
    send: (request) => fetch(request),
  });

  expect(exitCode).toBe(0);
  expect(stub.calls).toIncludeSameMembers(['sessions/list', 'conversation/read']);
  expect(ctx.stop).toHaveBeenCalledOnce();
  expect(ctx.printErr).not.toHaveBeenCalled();

  expect(ctx.printOut.mock.calls).toStrictEqual([
    ['statefulset rolling update complete 1 pods at revision nixie-7c9d5f6b8...\n'],
    ['sessions/list: refused without a session, as the contract says\n'],
    ['conversation/read: refused without a session, as the contract says\n'],
    ['nixie API check passed\n'],
  ]);
});

test('it fails without a call to nixie when the rollout does not finish', async () => {
  const ctx = setupTest();

  const stub = startStubNixieAPI({
    url: 'http://127.0.0.1:41873/api/v1/namespaces/nixie/services/http:nixie:http/proxy',
    enrolCodes: [],
    sequences: [],
    keepaliveMs: null,
    closeAfterMs: null,
  });

  const startProxy = mock<() => Promise<KubectlProxyStart>>();

  // kubectl's answer when --timeout runs out (k8s.io/apimachinery's wait.ErrWaitTimeout)
  const runner = buildStubRunner((call) =>
    call.argv.join(' ') ===
    'kubectl --namespace nixie rollout status statefulset/nixie --timeout=600s'
      ? {
          exitCode: 1,
          stdout: 'Waiting for 1 pods to be ready...\n',
          stderr: 'error: timed out waiting for the condition\n',
        }
      : undefined,
  );

  const exitCode = await runNixieAPICheck({
    run: runner.run,
    startProxy,
    printOut: ctx.printOut,
    printErr: ctx.printErr,
    send: (request) => fetch(request),
  });

  expect(exitCode).toBe(1);
  expect(startProxy).not.toHaveBeenCalled();
  expect(stub.calls).toBeEmpty();

  expect(ctx.printErr).toHaveBeenCalledExactlyOnceWith(
    "run-nixie-api-check: nixie's rollout did not finish (exit 1): error: timed out waiting for the condition\n",
  );
});

test('it fails without a call to nixie when the proxy does not start', async () => {
  const ctx = setupTest();

  const stub = startStubNixieAPI({
    url: 'http://127.0.0.1:41873/api/v1/namespaces/nixie/services/http:nixie:http/proxy',
    enrolCodes: [],
    sequences: [],
    keepaliveMs: null,
    closeAfterMs: null,
  });

  const runner = buildStubRunner((call) =>
    call.argv.join(' ') ===
    'kubectl --namespace nixie rollout status statefulset/nixie --timeout=600s'
      ? { stdout: 'statefulset rolling update complete 1 pods at revision nixie-7c9d5f6b8...\n' }
      : undefined,
  );

  const exitCode = await runNixieAPICheck({
    run: runner.run,
    startProxy: () =>
      Promise.resolve<KubectlProxyStart>({
        ok: false,
        error: 'kubectl proxy printed no address within 30000 ms',
      }),
    printOut: ctx.printOut,
    printErr: ctx.printErr,
    send: (request) => fetch(request),
  });

  expect(exitCode).toBe(1);
  expect(stub.calls).toBeEmpty();

  expect(ctx.printErr).toHaveBeenCalledExactlyOnceWith(
    'run-nixie-api-check: kubectl proxy printed no address within 30000 ms\n',
  );
});

test('it fails and still stops the proxy when nixie fails the check', async () => {
  const ctx = setupTest();

  // nothing listens on port 1, so each call fails to connect
  server.use(http.post(/^http:\/\/127\.0\.0\.1:1\//u, () => passthrough()));

  const runner = buildStubRunner((call) =>
    call.argv.join(' ') ===
    'kubectl --namespace nixie rollout status statefulset/nixie --timeout=600s'
      ? { stdout: 'statefulset rolling update complete 1 pods at revision nixie-7c9d5f6b8...\n' }
      : undefined,
  );

  const exitCode = await runNixieAPICheck({
    run: runner.run,
    startProxy: () =>
      Promise.resolve<KubectlProxyStart>({
        ok: true,
        proxy: { url: 'http://127.0.0.1:1', stop: ctx.stop },
      }),
    printOut: ctx.printOut,
    printErr: ctx.printErr,
    send: (request) => fetch(request),
  });

  expect(exitCode).toBe(1);
  expect(ctx.stop).toHaveBeenCalledOnce();
});
