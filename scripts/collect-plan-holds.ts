import { findJSONField } from './find-json-field.ts';

export function collectPlanHolds(digest: unknown): string[] {
  const steps = findJSONField(digest, 'steps');

  if (!Array.isArray(steps)) {
    return ['the plan lists no steps'];
  }

  const holds = steps.flatMap((step: unknown) => collectStepHolds(step));

  if (findJSONField(digest, 'maybeCorrupt') === true) {
    holds.push('the plan marks a resource as maybe corrupt');
  }

  const dataReplaces = steps.filter((step: unknown) => isRenamingDataReplace(step)).length;

  return [...holds, ...collectSummaryHolds(findJSONField(digest, 'changeSummary'), dataReplaces)];
}

// a refresh is not a change, and the drift check reports what it finds; read is a data source
const unattendedOps = new Set(['same', 'create', 'update', 'refresh', 'read']);

// the whole tailnet policy file, the VM and the cloud firewall in front of it, and the edge's
// say over who reaches the public hostnames: the tunnels' routes, the DNS records that point a
// hostname at a tunnel, and the Access login in front of the gateway's sign-in pages
const guardedTypes = new Set([
  'tailscale:index/acl:Acl',
  'cloudflare:index/dnsRecord:DnsRecord',
  'cloudflare:index/zeroTrustTunnelCloudflaredConfig:ZeroTrustTunnelCloudflaredConfig',
  'cloudflare:index/zeroTrustAccessApplication:ZeroTrustAccessApplication',
  'cloudflare:index/zeroTrustAccessPolicy:ZeroTrustAccessPolicy',
  'cloudflare:index/zeroTrustAccessIdentityProvider:ZeroTrustAccessIdentityProvider',
  'onidel:index:Vm',
  'onidel:index:FirewallGroup',
  'onidel:index:FirewallRule',
]);

const changeOps = new Set(['create', 'update']);

function collectStepHolds(step: unknown): string[] {
  const op = findJSONField(step, 'op');
  const urn = findJSONField(step, 'urn');

  if (typeof op !== 'string' || typeof urn !== 'string') {
    return ['the plan holds a step without an op or a URN'];
  }

  // fails closed: an op that a later Pulumi adds holds too
  if (!unattendedOps.has(op) && !isRenamingDataReplace(step)) {
    return [`${op} ${urn}`];
  }

  if (changeOps.has(op) && guardedTypes.has(getURNType(urn))) {
    return [`${op} of a guarded resource ${urn}`];
  }

  return [];
}

// pulumi-kubernetes replaces a Secret or a ConfigMap on any change to its data. One with no fixed
// name gets a new name, so its replacement exists before the old one goes and the workload that
// names it rolls onto the new data; one with a fixed name is deleted first, so it still holds.
const dataReplaceTypes = new Set(['kubernetes:core/v1:Secret', 'kubernetes:core/v1:ConfigMap']);

function isRenamingDataReplace(step: unknown): boolean {
  const urn = findJSONField(step, 'urn');
  const reasons = findJSONField(step, 'replaceReasons');

  if (findJSONField(step, 'op') !== 'replace' || typeof urn !== 'string') {
    return false;
  }

  if (!dataReplaceTypes.has(getURNType(urn)) || !Array.isArray(reasons) || reasons.length === 0) {
    return false;
  }

  const oldName = findInputName(findJSONField(step, 'oldState'));
  const newName = findInputName(findJSONField(step, 'newState'));

  return (
    reasons.every((reason: unknown) => isDataPath(reason)) &&
    typeof oldName === 'string' &&
    typeof newName === 'string' &&
    oldName !== newName
  );
}

function getURNType(urn: string): string {
  // urn:pulumi:<stack>::<project>::<parent types and the type, joined by $>::<name>
  const qualifiedType = urn.split('::')[2] ?? '';

  return qualifiedType.split('$').at(-1) ?? '';
}

function findInputName(state: unknown): unknown {
  return findJSONField(findJSONField(findJSONField(state, 'inputs'), 'metadata'), 'name');
}

const dataFields = new Set(['data', 'stringData', 'binaryData']);

function isDataPath(reason: unknown): boolean {
  // a property path such as data["secrets.yaml"] or data.token
  return typeof reason === 'string' && dataFields.has(reason.split(/[.[]/u)[0] ?? '');
}

function collectSummaryHolds(summary: unknown, dataReplaces: number): string[] {
  if (typeof summary !== 'object' || summary === null) {
    return [];
  }

  return Object.entries(summary)
    .filter(
      (entry: Readonly<[string, unknown]>) =>
        !unattendedOps.has(entry[0]) &&
        entry[1] !== 0 &&
        !(entry[0] === 'replace' && entry[1] === dataReplaces),
    )
    .map(
      (entry: Readonly<[string, unknown]>) =>
        `the plan's summary counts ${String(entry[1])} ${entry[0]}`,
    );
}
