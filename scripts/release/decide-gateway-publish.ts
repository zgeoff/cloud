export interface GatewayPublishInput {
  readonly eventName: string;
  readonly ref: string;

  // the push input of a manual run, as the runner passes it: 'true' or 'false'
  readonly pushInput: string;

  readonly changedFiles: readonly string[];
}

export type GatewayPublishDecision =
  | { readonly action: 'publish'; readonly reason: string }
  | { readonly action: 'skip'; readonly reason: string };

const gatewayPinFile = 'images/atc-gateway/versions.env';

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

  return input.changedFiles.includes(gatewayPinFile)
    ? { action: 'publish', reason: `the push to main changes ${gatewayPinFile}` }
    : { action: 'skip', reason: `the push to main leaves ${gatewayPinFile} as it was` };
}
