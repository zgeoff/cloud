import { expect, test } from 'bun:test';
import { collectPlanHolds } from './collect-plan-holds.ts';

test('it finds nothing to hold in a plan of creates, updates, refreshes and reads', () => {
  expect(
    collectPlanHolds({
      steps: [
        { op: 'same', urn: 'urn:pulumi:prod::geoff-cloud::pulumi:pulumi:Stack::geoff-cloud-prod' },
        {
          op: 'refresh',
          urn: 'urn:pulumi:prod::geoff-cloud::onidel:index:Vm::geoffcloud',
        },
        {
          op: 'update',
          urn: 'urn:pulumi:prod::geoff-cloud::kubernetes:apps/v1:StatefulSet::nixie',
          diffReasons: ['spec'],
        },
        {
          op: 'create',
          urn: 'urn:pulumi:prod::geoff-cloud::kubernetes:core/v1:ConfigMap::nixie-config',
        },
        {
          op: 'read',
          urn: 'urn:pulumi:prod::geoff-cloud::cloudflare:index/getZone:getZone::zone',
        },
      ],
      changeSummary: { same: 40, update: 1, create: 1 },
    }),
  ).toStrictEqual([]);
});

test.each([
  [
    'a Secret',
    'urn:pulumi:prod::geoff-cloud::kubernetes:core/v1:Secret::nixie-secrets',
    'data["secrets.yaml"]',
  ],
  [
    'a ConfigMap',
    'urn:pulumi:prod::geoff-cloud::kubernetes:core/v1:ConfigMap::nixie-config',
    'data["config.yaml"]',
  ],
  [
    'a ConfigMap by its binary data',
    'urn:pulumi:prod::geoff-cloud::kubernetes:core/v1:ConfigMap::nixie-config',
    'binaryData.logo',
  ],
])(
  'it finds nothing to hold when new data replaces %s under a new name',
  (_label: string, urn: string, reason: string) => {
    expect(
      collectPlanHolds({
        steps: [
          {
            op: 'same',
            urn: 'urn:pulumi:prod::geoff-cloud::pulumi:pulumi:Stack::geoff-cloud-prod',
          },
          {
            op: 'replace',
            urn,
            replaceReasons: [reason],
            oldState: { inputs: { metadata: { name: 'nixie-4c1d09ae', namespace: 'nixie' } } },
            newState: { inputs: { metadata: { name: 'nixie-e83b5f27', namespace: 'nixie' } } },
          },
          {
            op: 'update',
            urn: 'urn:pulumi:prod::geoff-cloud::kubernetes:apps/v1:StatefulSet::nixie',
            diffReasons: ['spec'],
          },
        ],
        changeSummary: { same: 1, replace: 1, update: 1 },
      }),
    ).toStrictEqual([]);
  },
);

test('it holds new data that replaces a Secret under the same name', () => {
  expect(
    collectPlanHolds({
      steps: [
        {
          op: 'replace',
          urn: 'urn:pulumi:prod::geoff-cloud::kubernetes:core/v1:Secret::files-backup',
          replaceReasons: ['data.RESTIC_PASSWORD'],
          oldState: { inputs: { metadata: { name: 'files-backup', namespace: 'files' } } },
          newState: { inputs: { metadata: { name: 'files-backup', namespace: 'files' } } },
        },
      ],
      changeSummary: { replace: 1 },
    }),
  ).toStrictEqual([
    'replace urn:pulumi:prod::geoff-cloud::kubernetes:core/v1:Secret::files-backup',
    "the plan's summary counts 1 replace",
  ]);
});

test('it holds a replace of a Secret that changes more than its data', () => {
  expect(
    collectPlanHolds({
      steps: [
        {
          op: 'replace',
          urn: 'urn:pulumi:prod::geoff-cloud::kubernetes:core/v1:Secret::nixie-secrets',
          replaceReasons: ['data["secrets.yaml"]', 'type'],
          oldState: { inputs: { metadata: { name: 'nixie-4c1d09ae', namespace: 'nixie' } } },
          newState: { inputs: { metadata: { name: 'nixie-e83b5f27', namespace: 'nixie' } } },
        },
      ],
      changeSummary: { replace: 1 },
    }),
  ).toStrictEqual([
    'replace urn:pulumi:prod::geoff-cloud::kubernetes:core/v1:Secret::nixie-secrets',
    "the plan's summary counts 1 replace",
  ]);
});

test('it holds a replace of a Secret that names no reason', () => {
  expect(
    collectPlanHolds({
      steps: [
        {
          op: 'replace',
          urn: 'urn:pulumi:prod::geoff-cloud::kubernetes:core/v1:Secret::nixie-secrets',
          replaceReasons: [],
          oldState: { inputs: { metadata: { name: 'nixie-4c1d09ae', namespace: 'nixie' } } },
          newState: { inputs: { metadata: { name: 'nixie-e83b5f27', namespace: 'nixie' } } },
        },
      ],
      changeSummary: { replace: 1 },
    }),
  ).toStrictEqual([
    'replace urn:pulumi:prod::geoff-cloud::kubernetes:core/v1:Secret::nixie-secrets',
    "the plan's summary counts 1 replace",
  ]);
});

test('it holds a data replace of a resource that is no Secret or ConfigMap', () => {
  expect(
    collectPlanHolds({
      steps: [
        {
          op: 'replace',
          urn: 'urn:pulumi:prod::geoff-cloud::kubernetes:apiextensions.k8s.io:CustomResource::bundle',
          replaceReasons: ['data.ca'],
          oldState: { inputs: { metadata: { name: 'bundle-4c1d09ae', namespace: 'nixie' } } },
          newState: { inputs: { metadata: { name: 'bundle-e83b5f27', namespace: 'nixie' } } },
        },
      ],
      changeSummary: { replace: 1 },
    }),
  ).toStrictEqual([
    'replace urn:pulumi:prod::geoff-cloud::kubernetes:apiextensions.k8s.io:CustomResource::bundle',
    "the plan's summary counts 1 replace",
  ]);
});

test('it holds a summary that counts more replaces than the data replaces it passes', () => {
  expect(
    collectPlanHolds({
      steps: [
        {
          op: 'replace',
          urn: 'urn:pulumi:prod::geoff-cloud::kubernetes:core/v1:Secret::nixie-secrets',
          replaceReasons: ['data["secrets.yaml"]'],
          oldState: { inputs: { metadata: { name: 'nixie-4c1d09ae', namespace: 'nixie' } } },
          newState: { inputs: { metadata: { name: 'nixie-e83b5f27', namespace: 'nixie' } } },
        },
      ],
      changeSummary: { replace: 2 },
    }),
  ).toStrictEqual(["the plan's summary counts 2 replace"]);
});

test('it holds each replace step of a plan', () => {
  expect(
    collectPlanHolds({
      steps: [
        {
          op: 'replace',
          urn: 'urn:pulumi:prod::geoff-cloud::kubernetes:core/v1:Secret::atc-gateway-tokens',
          replaceReasons: ['metadata'],
        },
        {
          op: 'create-replacement',
          urn: 'urn:pulumi:prod::geoff-cloud::kubernetes:core/v1:Secret::atc-gateway-tokens',
        },
        {
          op: 'delete-replaced',
          urn: 'urn:pulumi:prod::geoff-cloud::kubernetes:core/v1:Secret::atc-gateway-tokens',
        },
      ],
      changeSummary: { replace: 1, same: 40 },
    }),
  ).toStrictEqual([
    'replace urn:pulumi:prod::geoff-cloud::kubernetes:core/v1:Secret::atc-gateway-tokens',
    'create-replacement urn:pulumi:prod::geoff-cloud::kubernetes:core/v1:Secret::atc-gateway-tokens',
    'delete-replaced urn:pulumi:prod::geoff-cloud::kubernetes:core/v1:Secret::atc-gateway-tokens',
    "the plan's summary counts 1 replace",
  ]);
});

test('it holds a delete', () => {
  expect(
    collectPlanHolds({
      steps: [
        {
          op: 'delete',
          urn: 'urn:pulumi:prod::geoff-cloud::cloudflare:index/r2Bucket:R2Bucket::backups',
        },
      ],
    }),
  ).toStrictEqual([
    'delete urn:pulumi:prod::geoff-cloud::cloudflare:index/r2Bucket:R2Bucket::backups',
  ]);
});

test('it holds an op it does not know', () => {
  expect(
    collectPlanHolds({
      steps: [{ op: 'import', urn: 'urn:pulumi:prod::geoff-cloud::onidel:index:SshKey::admin' }],
    }),
  ).toStrictEqual(['import urn:pulumi:prod::geoff-cloud::onidel:index:SshKey::admin']);
});

test.each([
  ['the tailnet policy', 'urn:pulumi:prod::geoff-cloud::tailscale:index/acl:Acl::tailnet-policy'],
  ['the VM', 'urn:pulumi:prod::geoff-cloud::onidel:index:Vm::geoffcloud'],
  ['the firewall group', 'urn:pulumi:prod::geoff-cloud::onidel:index:FirewallGroup::edge'],
  ['a firewall rule', 'urn:pulumi:prod::geoff-cloud::onidel:index:FirewallRule::edge-https'],
  [
    "the tunnel's routes",
    'urn:pulumi:prod::geoff-cloud::cloudflare:index/zeroTrustTunnelCloudflaredConfig:ZeroTrustTunnelCloudflaredConfig::edge',
  ],
  ['a DNS record', 'urn:pulumi:prod::geoff-cloud::cloudflare:index/dnsRecord:DnsRecord::atc'],
  [
    'the Access application',
    'urn:pulumi:prod::geoff-cloud::cloudflare:index/zeroTrustAccessApplication:ZeroTrustAccessApplication::atc-gateway-sign-in',
  ],
  [
    'the Access policy',
    'urn:pulumi:prod::geoff-cloud::cloudflare:index/zeroTrustAccessPolicy:ZeroTrustAccessPolicy::atc-gateway-owner',
  ],
  [
    'the Access identity provider',
    'urn:pulumi:prod::geoff-cloud::cloudflare:index/zeroTrustAccessIdentityProvider:ZeroTrustAccessIdentityProvider::one-time-pin',
  ],
])('it holds an update of %s', (_label: string, urn: string) => {
  expect(collectPlanHolds({ steps: [{ op: 'update', urn }] })).toStrictEqual([
    `update of a guarded resource ${urn}`,
  ]);
});

test('it holds the create of a guarded resource under a parent component', () => {
  expect(
    collectPlanHolds({
      steps: [
        {
          op: 'create',
          urn: 'urn:pulumi:prod::geoff-cloud::cloud:edge:Edge$onidel:index:FirewallRule::edge-ssh',
        },
      ],
    }),
  ).toStrictEqual([
    'create of a guarded resource urn:pulumi:prod::geoff-cloud::cloud:edge:Edge$onidel:index:FirewallRule::edge-ssh',
  ]);
});

test('it holds a plan that marks a resource as maybe corrupt', () => {
  expect(
    collectPlanHolds({
      steps: [
        { op: 'same', urn: 'urn:pulumi:prod::geoff-cloud::pulumi:pulumi:Stack::geoff-cloud-prod' },
      ],
      maybeCorrupt: true,
    }),
  ).toStrictEqual(['the plan marks a resource as maybe corrupt']);
});

test('it holds a summary that counts a delete no step shows', () => {
  expect(
    collectPlanHolds({
      steps: [
        { op: 'same', urn: 'urn:pulumi:prod::geoff-cloud::pulumi:pulumi:Stack::geoff-cloud-prod' },
      ],
      changeSummary: { same: 1, delete: 2 },
    }),
  ).toStrictEqual(["the plan's summary counts 2 delete"]);
});

test('it holds a step without an op', () => {
  expect(
    collectPlanHolds({
      steps: [{ urn: 'urn:pulumi:prod::geoff-cloud::onidel:index:Vm::geoffcloud' }],
    }),
  ).toStrictEqual(['the plan holds a step without an op or a URN']);
});

test.each([
  ['a digest without steps', { changeSummary: { same: 1 } }],
  ['a string', 'Previewing update (prod)'],
  ['nothing', undefined],
])('it holds %s', (_label: string, digest: unknown) => {
  expect(collectPlanHolds(digest)).toStrictEqual(['the plan lists no steps']);
});
