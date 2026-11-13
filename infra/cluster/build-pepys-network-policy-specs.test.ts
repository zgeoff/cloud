import { expect, test } from 'bun:test';
import { buildPepysNetworkPolicySpecs } from './build-pepys-network-policy-specs.ts';

test('it admits Garage only from s2-lite and the backup, on the S3 port', () => {
  expect(buildPepysNetworkPolicySpecs(false)['pepys-garage']).toStrictEqual({
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
  expect(buildPepysNetworkPolicySpecs(false)['pepys-s2']?.ingress).toStrictEqual([
    {
      from: [
        { podSelector: { matchLabels: { app: 'pepys-ingest' } } },
        { podSelector: { matchLabels: { app: 'pepys-host' } } },
      ],
      ports: [{ protocol: 'TCP', port: 8080 }],
    },
  ]);
});

test("it admits ingest only from the shared tunnel's cloudflared and the boxxy server, on the ingest port", () => {
  expect(buildPepysNetworkPolicySpecs(false)['pepys-ingest']?.ingress).toStrictEqual([
    {
      from: [
        {
          namespaceSelector: { matchLabels: { 'kubernetes.io/metadata.name': 'ingress' } },
          podSelector: { matchLabels: { app: 'cloudflared' } },
        },
        {
          namespaceSelector: { matchLabels: { 'kubernetes.io/metadata.name': 'boxxy' } },
          podSelector: { matchLabels: { app: 'boxxy-server' } },
        },
      ],
      ports: [{ protocol: 'TCP', port: 8080 }],
    },
  ]);
});

test('it admits the host only from the boxxy server, on the API port, while the API is not public', () => {
  expect(buildPepysNetworkPolicySpecs(false)['pepys-host']?.ingress).toStrictEqual([
    {
      from: [
        {
          namespaceSelector: { matchLabels: { 'kubernetes.io/metadata.name': 'boxxy' } },
          podSelector: { matchLabels: { app: 'boxxy-server' } },
        },
      ],
      ports: [{ protocol: 'TCP', port: 8081 }],
    },
  ]);
});

test('it admits no pod to the backup', () => {
  expect(buildPepysNetworkPolicySpecs(false)['pepys-backup']?.ingress).toStrictEqual([]);
});

test("it admits the shared tunnel's cloudflared to the API port while the API is public", () => {
  expect(buildPepysNetworkPolicySpecs(true)['pepys-host']?.ingress).toStrictEqual([
    {
      from: [
        {
          namespaceSelector: { matchLabels: { 'kubernetes.io/metadata.name': 'ingress' } },
          podSelector: { matchLabels: { app: 'cloudflared' } },
        },
        {
          namespaceSelector: { matchLabels: { 'kubernetes.io/metadata.name': 'boxxy' } },
          podSelector: { matchLabels: { app: 'boxxy-server' } },
        },
      ],
      ports: [{ protocol: 'TCP', port: 8081 }],
    },
  ]);
});
