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
