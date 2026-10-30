import type { RegistryAnswer } from '../try-read-manifest-digest.ts';

export interface PinnedImage {
  readonly reference: string;

  readonly answer: RegistryAnswer;
}

export interface GatewayPublishInput {
  readonly eventName: string;
  readonly ref: string;

  // the push input of a manual run, as the runner passes it: 'true' or 'false'
  readonly pushInput: string;

  readonly pinnedImages: readonly PinnedImage[];
}

export type GatewayPublishDecision =
  | { readonly action: 'publish'; readonly reason: string }
  | { readonly action: 'skip'; readonly reason: string }
  | { readonly action: 'unknown'; readonly reason: string };

export function decideGatewayPublish(input: GatewayPublishInput): GatewayPublishDecision {
  if (input.ref !== 'refs/heads/main') {
    return { action: 'skip', reason: `${input.ref} is not main, and only main publishes` };
  }

  if (input.eventName === 'workflow_dispatch') {
    return input.pushInput === 'true'
      ? { action: 'publish', reason: 'a manual run on main asked to push' }
      : { action: 'skip', reason: 'a manual run without push: true only tests the images' };
  }

  if (input.eventName !== 'push') {
    return { action: 'skip', reason: `a ${input.eventName} event never publishes` };
  }

  const unread = input.pinnedImages.flatMap((image) =>
    'error' in image.answer ? [`${image.reference} (${image.answer.error})`] : [],
  );

  if (unread.length > 0) {
    return {
      action: 'unknown',
      reason: `cannot tell whether a pinned tag is published: ${unread.join(', ')}`,
    };
  }

  const missing = input.pinnedImages.flatMap((image) =>
    'missing' in image.answer ? [image.reference] : [],
  );

  return missing.length > 0
    ? { action: 'publish', reason: `the registry lacks ${missing.join(' and ')}` }
    : { action: 'skip', reason: 'the registry holds every pinned tag' };
}
