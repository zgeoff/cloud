import type { Output } from '@pulumi/pulumi';
import type { GHCRPullCredential } from '../inputs/index.ts';

// the fixed name each namespace's pull Secret takes, which the restore Jobs' YAML names too
export const ghcrPullSecretName = 'ghcr-pull';

// the registry the gateway's and the backup's images live in
const registry = 'ghcr.io';

// A namespace's kubernetes.io/dockerconfigjson pull Secret: the credential as GHCR's basic auth.
// The token enters only inside the Output's apply, so the JSON stays secret as the token is, and
// travels to the k3s API in the request body, never on a command line.
export function buildGHCRPullSecretArgs(namespace: Output<string>, credential: GHCRPullCredential) {
  return {
    metadata: { name: ghcrPullSecretName, namespace },
    type: 'kubernetes.io/dockerconfigjson',
    stringData: {
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
