import type { Output } from '@pulumi/pulumi';

export function resolveOutput<T>(value: Output<T>): Promise<T> {
  const pending = Promise.withResolvers<T>();

  // an unknown Output, as in a preview, skips apply's callback, so the promise never settles
  value.apply(pending.resolve);

  return pending.promise;
}
