interface StubR2Bucket {
  readonly objects: Map<string, string>;
  readonly get: (key: string) => Promise<{ readonly text: () => Promise<string> } | null>;
  readonly put: (key: string, value: string) => Promise<undefined>;
}

// A stand-in for a Workers R2 bucket binding, over an in-memory map: get resolves an
// object whose text() is the stored value, or null for a key never put, as R2 does; put
// replaces the value. objects exposes the map so a test can read what was stored.
export function buildStubR2Bucket(initial: Readonly<Record<string, string>> = {}): StubR2Bucket {
  const objects = new Map(Object.entries(initial));

  return {
    objects,
    get: (key) => {
      const value = objects.get(key);
      const stored = value === undefined ? null : { text: () => Promise.resolve(value) };

      return Promise.resolve(stored);
    },
    put: (key, value) => {
      objects.set(key, value);

      return Promise.resolve(undefined);
    },
  };
}
