import { expect, test } from 'bun:test';
import { buildPepysNetworkPolicySpecs } from './build-pepys-network-policy-specs.ts';

test('it admits Garage only from s2-lite and the backup, on the S3 port', () => {
  expect(
    buildPepysNetworkPolicySpecs({
      isPublic: false,
      isTailnetRouted: false,
      isForwarderRouted: false,
    })['pepys-garage'],
  ).toStrictEqual({
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
  expect(
    buildPepysNetworkPolicySpecs({
      isPublic: false,
      isTailnetRouted: false,
      isForwarderRouted: false,
    })['pepys-s2']?.ingress,
  ).toStrictEqual([
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
  expect(
    buildPepysNetworkPolicySpecs({
      isPublic: false,
      isTailnetRouted: false,
      isForwarderRouted: false,
    })['pepys-ingest']?.ingress,
  ).toStrictEqual([
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
  expect(
    buildPepysNetworkPolicySpecs({
      isPublic: false,
      isTailnetRouted: false,
      isForwarderRouted: false,
    })['pepys-host']?.ingress,
  ).toStrictEqual([
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
  expect(
    buildPepysNetworkPolicySpecs({
      isPublic: false,
      isTailnetRouted: false,
      isForwarderRouted: false,
    })['pepys-backup']?.ingress,
  ).toStrictEqual([]);
});

test("it admits the shared tunnel's cloudflared to the API port while the API is public", () => {
  expect(
    buildPepysNetworkPolicySpecs({
      isPublic: true,
      isTailnetRouted: false,
      isForwarderRouted: false,
    })['pepys-host']?.ingress,
  ).toStrictEqual([
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

test("it admits only nixie's Traefik to the API port on the tailnet route's rule", () => {
  expect(
    buildPepysNetworkPolicySpecs({
      isPublic: false,
      isTailnetRouted: true,
      isForwarderRouted: false,
    })['pepys-host']?.ingress,
  ).toStrictEqual([
    {
      from: [
        {
          namespaceSelector: { matchLabels: { 'kubernetes.io/metadata.name': 'boxxy' } },
          podSelector: { matchLabels: { app: 'boxxy-server' } },
        },
      ],
      ports: [{ protocol: 'TCP', port: 8081 }],
    },
    {
      from: [
        {
          namespaceSelector: { matchLabels: { 'kubernetes.io/metadata.name': 'nixie-ingress' } },
          podSelector: { matchLabels: { 'app.kubernetes.io/name': 'traefik' } },
        },
      ],
      ports: [{ protocol: 'TCP', port: 8081 }],
    },
  ]);
});

test("it admits nixie's Traefik to ingest's port, and to no other pod, while the forwarders' route is on", () => {
  const specs = buildPepysNetworkPolicySpecs({
    isPublic: false,
    isTailnetRouted: false,
    isForwarderRouted: true,
  });

  expect(specs['pepys-ingest']?.ingress).toStrictEqual([
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
    {
      from: [
        {
          namespaceSelector: { matchLabels: { 'kubernetes.io/metadata.name': 'nixie-ingress' } },
          podSelector: { matchLabels: { 'app.kubernetes.io/name': 'traefik' } },
        },
      ],
      ports: [{ protocol: 'TCP', port: 8080 }],
    },
  ]);

  expect(specs['pepys-host']?.ingress).toStrictEqual(
    buildPepysNetworkPolicySpecs({
      isPublic: false,
      isTailnetRouted: false,
      isForwarderRouted: false,
    })['pepys-host']?.ingress,
  );
});
