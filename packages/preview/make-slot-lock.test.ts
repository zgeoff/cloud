import { expect, test } from 'bun:test';
import { makeSlotLock } from './make-slot-lock.ts';

test('it runs a second callback only after the first one settles', async () => {
  const withSlotLock = makeSlotLock();
  const events: string[] = [];
  const firstGate = Promise.withResolvers<void>();

  const first = withSlotLock(async () => {
    events.push('first starts');

    await firstGate.promise;

    events.push('first ends');
  });

  const second = withSlotLock(() => {
    events.push('second runs');

    return Promise.resolve();
  });

  firstGate.resolve();

  await Promise.all([first, second]);

  expect(events).toStrictEqual(['first starts', 'first ends', 'second runs']);
});

test('it releases the lock after a callback rejects', async () => {
  const withSlotLock = makeSlotLock();

  const failing = withSlotLock(() =>
    Promise.reject(new Error('impd LEASED: the imp holds a lease')),
  );

  const next = withSlotLock(() => Promise.resolve('ran'));

  const result = await next;

  expect(failing).rejects.toThrowWithMessage(Error, 'impd LEASED: the imp holds a lease');
  expect(result).toBe('ran');
});
