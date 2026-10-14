import type { Provider } from '@pulumi/kubernetes';
import { Secret } from '@pulumi/kubernetes/core/v1';
import type { Output } from '@pulumi/pulumi';
import type { GHCRPullCredential } from '../inputs/index.ts';
import { buildGHCRPullSecretArgs } from './build-ghcr-pull-secret-args.ts';

interface GHCRPullSecretInputs {
  // the Pulumi resource name, one per namespace: atc-ghcr-pull, nixie-ghcr-pull
  readonly resourceName: string;
  readonly namespace: Output<string>;
  readonly credential: GHCRPullCredential;
}

// A namespace's pull Secret for the private GHCR images, under a fixed name: a rotated token
// updates it in place, and the kubelet reads it at the next pull without rolling any pod.
export function createGHCRPullSecret(cluster: Provider, inputs: GHCRPullSecretInputs): Secret {
  return new Secret(
    inputs.resourceName,
    buildGHCRPullSecretArgs(inputs.namespace, inputs.credential),
    { provider: cluster },
  );
}
