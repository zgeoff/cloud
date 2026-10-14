import { expect, test } from 'bun:test';
import { loadATCCredentialsContext } from './load-atc-credentials-context.ts';
import { runOp } from './run-op.ts';
import { buildStubRunner } from './test-utils/build-stub-runner.ts';

test('it runs op with the service account token in its environment and the stdin it gets', async () => {
  const stub = buildStubRunner(() => ({ stdout: '{"id":"fixture-item-id"}\n' }));

  const context = await loadATCCredentialsContext({
    run: stub.run,
    env: { OP_SERVICE_ACCOUNT_TOKEN: 'ops_fixture_env' },
    printOut: () => {},
    printErr: () => {},
  });

  const stdout = await runOp(
    context,
    ['item', 'create', '--vault', 'cloud', '-'],
    Buffer.from('{}'),
  );

  expect(stdout).toBe('{"id":"fixture-item-id"}\n');

  expect(stub.calls).toStrictEqual([
    {
      argv: ['op', 'item', 'create', '--vault', 'cloud', '-'],
      stdin: '{}',
      options: { env: { OP_SERVICE_ACCOUNT_TOKEN: 'ops_fixture_env' } },
    },
  ]);
});
