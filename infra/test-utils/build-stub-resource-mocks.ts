import type { runtime } from '@pulumi/pulumi';
import { z } from 'zod';

// outputs holds the state a provider computes, such as a certificate's PEM, by registration key
export function buildStubResourceMocks(
  held: readonly string[] = [],
  outputs: Readonly<Record<string, Record<string, unknown>>> = {},
): {
  readonly mocks: runtime.Mocks;
  readonly registered: string[];
  readonly inputs: Map<string, Record<string, unknown>>;
  readonly whenRegistered: (key: string) => Promise<void>;
  readonly release: () => void;
  readonly releaseKey: (key: string) => void;
} {
  const registered: string[] = [];

  const inputs = new Map<string, Record<string, unknown>>();
  const started = new Map<string, PromiseWithResolvers<void>>();
  const gates = new Map(held.map((key) => [key, Promise.withResolvers<void>()]));

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
      for (const gate of gates.values()) {
        gate.resolve();
      }
    },
    releaseKey: (key: string) => {
      gates.get(key)?.resolve();
    },
    mocks: {
      newResource: async (args: runtime.MockResourceArgs) => {
        const key = `${args.type}::${args.name}`;
        const state = inputsSchema.parse(args.inputs);

        registered.push(key);
        inputs.set(key, state);

        getStarted(key).resolve();

        await gates.get(key)?.promise;

        return { id: `${args.name}-id`, state: { ...state, ...outputs[key] } };
      },
      call: (args: runtime.MockCallArgs) => inputsSchema.parse(args.inputs),
    },
  };
}
