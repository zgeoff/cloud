import { expect, test } from 'bun:test';
import { buildNixieVerifyKubeconfig } from './build-nixie-verify-kubeconfig.ts';

test("it builds a kubeconfig that holds the cluster's server and CA and the account's token, in the nixie namespace", () => {
  const text = buildNixieVerifyKubeconfig(
    { server: 'https://cluster.example.test:6443', certificateAuthorityData: 'Y2EtZm9yLXRlc3Rz' },
    'fake-token-for-tests',
  );

  expect(Bun.YAML.parse(text)).toStrictEqual({
    apiVersion: 'v1',
    kind: 'Config',
    clusters: [
      {
        name: 'geoff-cloud',
        cluster: {
          server: 'https://cluster.example.test:6443',
          'certificate-authority-data': 'Y2EtZm9yLXRlc3Rz',
        },
      },
    ],
    users: [{ name: 'nixie-verify', user: { token: 'fake-token-for-tests' } }],
    contexts: [
      {
        name: 'nixie-verify',
        context: { cluster: 'geoff-cloud', user: 'nixie-verify', namespace: 'nixie' },
      },
    ],
    'current-context': 'nixie-verify',
  });
});
