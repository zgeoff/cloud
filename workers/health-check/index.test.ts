import { expect, test } from 'bun:test';
import { buildStubR2Bucket } from '../../infra/test-utils/build-stub-r2-bucket.ts';
import { targetStatuses } from '../mocks/target-statuses.ts';
import handler from './index.ts';

// The module Workers loads: its default export's scheduled runs the check. The log line goes to
// the real console, which this test leaves alone; make-scheduled-handler.test.ts asserts it.
test('it records each target the cron checks through the default export', async () => {
  targetStatuses.set('https://atc.geoff.cloud/', 530);

  const bucket = buildStubR2Bucket();

  await handler.scheduled(undefined, {
    STATE: bucket,
    TARGETS: JSON.stringify([{ name: 'atc', url: 'https://atc.geoff.cloud/' }]),
  });

  expect(Object.fromEntries(bucket.objects)).toStrictEqual({ 'state:atc': 'tunnel-down' });
});
