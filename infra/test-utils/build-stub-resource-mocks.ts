import type { runtime } from '@pulumi/pulumi';

// Pulumi mocks that record each resource registration as `<type>::<name>`, in the order the
// engine receives them. A registration whose key is in held stays pending, as a slow provider
// call would, until release is called; whenRegistered resolves once a key's registration starts.
export function buildStubResourceMocks(held: readonly string[] = []): {
  readonly mocks: runtime.Mocks;
  readonly registered: string[];
  readonly whenRegistered: (key: string) => Promise<void>;
  readonly release: () => void;
} {
  const registered: string[] = [];

  const started = new Map<string, PromiseWithResolvers<void>>();

  const gate = Promise.withResolvers<void>();

  const getStarted = (key: string): PromiseWithResolvers<void> => {
    const existing = started.get(key) ?? Promise.withResolvers<void>();

    started.set(key, existing);

    return existing;
  };

  return {
    registered,
    whenRegistered: (key: string) => getStarted(key).promise,
    release: () => {
      gate.resolve();
    },
    mocks: {
      newResource: async (args: runtime.MockResourceArgs) => {
        const key = `${args.type}::${args.name}`;

        registered.push(key);

        getStarted(key).resolve();

        if (held.includes(key)) {
          await gate.promise;
        }

        return { id: `${args.name}-id`, state: args.inputs };
      },
      call: (args: runtime.MockCallArgs) => args.inputs,
    },
  };
}
