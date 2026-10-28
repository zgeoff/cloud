import type { Provider } from '@pulumi/kubernetes';
import type { CustomResourceOptions, Resource } from '@pulumi/pulumi';

// Pulumi waits for readiness, and nixie turns ready only once impd has pulled its sandbox images
// and booted the conversation imp, which a cold start takes longer than Pulumi's default wait
export const nixieRolloutTimeouts = { create: '30m', update: '30m' };

export interface NixieStatefulSetOptionsInputs {
  readonly cluster: Provider;
  readonly sandboxImages: Resource;
}

// Pulumi leaves the StatefulSet unchanged when the Command it depends on fails, so a failed add of
// the sandbox images stops the roll
export function buildNixieStatefulSetOptions(
  inputs: NixieStatefulSetOptionsInputs,
): CustomResourceOptions {
  return {
    provider: inputs.cluster,
    customTimeouts: nixieRolloutTimeouts,
    dependsOn: [inputs.sandboxImages],
  };
}
