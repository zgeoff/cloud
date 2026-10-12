import { expect, test } from 'bun:test';
import { buildStubNixieRecord } from './build-stub-nixie-record.ts';

test('it builds a message record of the conversation thread with the fields nixie 0.3.0 requires', () => {
  expect(buildStubNixieRecord(7)).toStrictEqual({
    kind: 'message',
    message: { text: 'record 7' },
    recordedAt: '2026-10-12T00:00:07.000Z',
    sequence: 7,
    thread: 'conversation',
  });
});

test('it records each later sequence later', () => {
  expect(new Date(buildStubNixieRecord(8).recordedAt)).toBeAfter(
    new Date(buildStubNixieRecord(7).recordedAt),
  );
});
