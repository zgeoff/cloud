import type { Output } from '@pulumi/pulumi';

// The value an Output holds, once it resolves. An Output a test builds from a value is
// known, so apply runs its callback; an unknown one, as in a preview, skips it, and the
// promise never settles.
export function resolveOutput<T>(value: Output<T>): Promise<T> {
  const pending = Promise.withResolvers<T>();

  value.apply(pending.resolve);

  return pending.promise;
}
