import type { Provider } from '@pulumi/kubernetes';
import { Secret } from '@pulumi/kubernetes/core/v1';
import type { Output } from '@pulumi/pulumi';
import type { GHCRPullCredential } from '../inputs/index.ts';
import { buildGHCRPullSecretArgs } from './build-ghcr-pull-secret-args.ts';

interface GHCRPullSecretInputs {
  readonly resourceName: string;
  readonly namespace: Output<string>;
  readonly credential: GHCRPullCredential;
}

export function createGHCRPullSecret(cluster: Provider, inputs: GHCRPullSecretInputs): Secret {
  return new Secret(
    inputs.resourceName,
    buildGHCRPullSecretArgs(inputs.namespace, inputs.credential),
    { provider: cluster },
  );
}
