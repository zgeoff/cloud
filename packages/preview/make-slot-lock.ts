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
