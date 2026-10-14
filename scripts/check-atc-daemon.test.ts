import { expect, test } from 'bun:test';
import { checkATCDaemon } from './check-atc-daemon.ts';
import { buildStubRunner } from './test-utils/build-stub-runner.ts';

test('it passes an active daemon', async () => {
  const stub = buildStubRunner(() => ({}));

  const line = await checkATCDaemon({ run: stub.run, host: 'geoffcloud' });

  expect(line).toStrictEqual({ status: 'ok', text: 'atc-daemon is active on geoffcloud' });
  expect(stub.calls[0]?.argv.at(-1)).toBe("'systemctl' 'is-active' '--quiet' 'atc-daemon'");
});

test('it reports an inactive daemon as missing', async () => {
  const stub = buildStubRunner(() => ({ exitCode: 3 }));

  const line = await checkATCDaemon({ run: stub.run, host: 'geoffcloud' });

  expect(line).toStrictEqual({ status: 'missing', text: 'atc-daemon service on geoffcloud' });
});
