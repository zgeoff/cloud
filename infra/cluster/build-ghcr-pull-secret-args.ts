import type { Output } from '@pulumi/pulumi';
import type { GHCRPullCredential } from '../inputs/index.ts';

// Fixed, because the restore Jobs' YAML names it too, and so a rotated token updates it in place,
// which the kubelet reads at the next pull without rolling any pod.
export const ghcrPullSecretName = 'ghcr-pull';
const registry = 'ghcr.io';

export function buildGHCRPullSecretArgs(namespace: Output<string>, credential: GHCRPullCredential) {
  return {
    metadata: { name: ghcrPullSecretName, namespace },
    type: 'kubernetes.io/dockerconfigjson',
    stringData: {
      // The token enters only inside the Output's apply, so the JSON stays secret as the token is,
      // and travels to the k3s API in the request body, never on a command line.
      '.dockerconfigjson': credential.token.apply((token) =>
        JSON.stringify({
          auths: {
            [registry]: {
              username: credential.username,
              password: token,
              auth: Buffer.from(`${credential.username}:${token}`).toString('base64'),
            },
          },
        }),
      ),
    },
  };
}
