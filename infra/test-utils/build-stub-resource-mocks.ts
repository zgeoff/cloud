import type { runtime } from '@pulumi/pulumi';
import { z } from 'zod';

// Pulumi mocks that record each registration's `<type>::<name>` key in order, and its inputs by
// key. A registration whose key is in held stays pending, as a slow provider call would, until
// release; whenRegistered resolves once a key's registration starts.
export function buildStubResourceMocks(held: readonly string[] = []): {
  readonly mocks: runtime.Mocks;
  readonly registered: string[];
  readonly inputs: Map<string, Record<string, unknown>>;
  readonly whenRegistered: (key: string) => Promise<void>;
  readonly release: () => void;
} {
  const registered: string[] = [];

  const inputs = new Map<string, Record<string, unknown>>();
  const started = new Map<string, PromiseWithResolvers<void>>();

  const gate = Promise.withResolvers<void>();

  // Pulumi types a registration's inputs as any
  const inputsSchema = z.record(z.string(), z.unknown());

  const getStarted = (key: string): PromiseWithResolvers<void> => {
    const existing = started.get(key) ?? Promise.withResolvers<void>();

    started.set(key, existing);

    return existing;
  };

  return {
    registered,
    inputs,
    whenRegistered: (key: string) => getStarted(key).promise,
    release: () => {
      gate.resolve();
    },
    mocks: {
      newResource: async (args: runtime.MockResourceArgs) => {
        const key = `${args.type}::${args.name}`;
        const state = inputsSchema.parse(args.inputs);

        registered.push(key);
        inputs.set(key, state);

        getStarted(key).resolve();

        if (held.includes(key)) {
          await gate.promise;
        }

        return { id: `${args.name}-id`, state };
      },
      call: (args: runtime.MockCallArgs) => inputsSchema.parse(args.inputs),
    },
  };
}
