import { expect, test } from 'bun:test';
import { buildPepysNetworkPolicySpecs } from './build-pepys-network-policy-specs.ts';

test('it admits Garage only from s2-lite and the backup, on the S3 port', () => {
  expect(buildPepysNetworkPolicySpecs()['pepys-garage']).toStrictEqual({
    podSelector: { matchLabels: { app: 'pepys-garage' } },
    policyTypes: ['Ingress'],
    ingress: [
      {
        from: [
          { podSelector: { matchLabels: { app: 'pepys-s2' } } },
          { podSelector: { matchLabels: { app: 'pepys-backup' } } },
        ],
        ports: [{ protocol: 'TCP', port: 3900 }],
      },
    ],
  });
});

test('it admits s2-lite only from ingest and the host', () => {
  expect(buildPepysNetworkPolicySpecs()['pepys-s2']?.ingress).toStrictEqual([
    {
      from: [
        { podSelector: { matchLabels: { app: 'pepys-ingest' } } },
        { podSelector: { matchLabels: { app: 'pepys-host' } } },
      ],
      ports: [{ protocol: 'TCP', port: 8080 }],
    },
  ]);
});

test("it admits ingest only from the shared tunnel's cloudflared", () => {
  expect(buildPepysNetworkPolicySpecs()['pepys-ingest']?.ingress).toStrictEqual([
    {
      from: [
        {
          namespaceSelector: { matchLabels: { 'kubernetes.io/metadata.name': 'ingress' } },
          podSelector: { matchLabels: { app: 'cloudflared' } },
        },
      ],
      ports: [{ protocol: 'TCP', port: 8080 }],
    },
  ]);
});

test.each(['pepys-host', 'pepys-backup'])('it admits no pod to %s', (name) => {
  expect(buildPepysNetworkPolicySpecs()[name]?.ingress).toStrictEqual([]);
});
