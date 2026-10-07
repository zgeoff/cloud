import type { Output } from '@pulumi/pulumi';

// The value an Output holds, once it resolves. Outside a Pulumi run every Output is known,
// so apply always runs its callback.
export function readOutput<T>(value: Output<T>): Promise<T> {
  const pending = Promise.withResolvers<T>();

  value.apply(pending.resolve);

  return pending.promise;
}
