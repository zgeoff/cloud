export interface NixieVerifyCluster {
  readonly server: string;
  readonly certificateAuthorityData: string;
}

// A kubeconfig for the nixie-verify service account, in the nixie namespace. JSON is YAML, so
// kubectl reads the text as it is.
export function buildNixieVerifyKubeconfig(cluster: NixieVerifyCluster, token: string): string {
  const config = {
    apiVersion: 'v1',
    kind: 'Config',
    clusters: [
      {
        name: 'geoff-cloud',
        cluster: {
          server: cluster.server,
          'certificate-authority-data': cluster.certificateAuthorityData,
        },
      },
    ],
    users: [{ name: 'nixie-verify', user: { token } }],
    contexts: [
      {
        name: 'nixie-verify',
        context: { cluster: 'geoff-cloud', user: 'nixie-verify', namespace: 'nixie' },
      },
    ],
    'current-context': 'nixie-verify',
  };

  return `${JSON.stringify(config, null, 2)}\n`;
}
