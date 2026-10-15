// Runs one callback at a time, in call order, so the slot rule sees every imp that an earlier
// open started before it plans: the check of the running imps and the start of the opening one
// form one step. A callback that rejects still releases the lock for the next.
export function makeSlotLock(): <T>(run: () => Promise<T>) => Promise<T> {
  let tail: Promise<void> = Promise.resolve();

  return async <T>(run: () => Promise<T>): Promise<T> => {
    const previous = tail;
    const turn = Promise.withResolvers<void>();

    tail = turn.promise;

    await previous;

    try {
      return await run();
    } finally {
      turn.resolve();
    }
  };
}
