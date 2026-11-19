import { expect, test } from 'bun:test';
import handler from './index.ts';
import { buildStubR2Bucket } from './src/test-utils/build-stub-r2-bucket.ts';
import { targetStatuses } from './src/test-utils/target-statuses.ts';

// The log line goes to the real console, which this test leaves alone; the handler's own test
// asserts it.
test('it records each target the cron checks through the default export', async () => {
  targetStatuses.set('https://atc.geoff.cloud/', 530);

  const bucket = buildStubR2Bucket();

  await handler.scheduled(undefined, {
    STATE: bucket,
    TARGETS: JSON.stringify([{ name: 'atc', url: 'https://atc.geoff.cloud/' }]),
  });

  expect(Object.fromEntries(bucket.objects)).toStrictEqual({ 'state:atc': 'tunnel-down' });
});
