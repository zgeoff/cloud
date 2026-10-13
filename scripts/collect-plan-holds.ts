import { findJSONField } from './find-json-field.ts';

// The reasons a planned prod apply must wait for a person, from `pulumi preview --json`'s digest;
// none lets it run unattended. It fails closed: an op outside the allowed list holds, so an op a
// later Pulumi adds holds too, and so does a digest it cannot read.
export function collectPlanHolds(digest: unknown): string[] {
  const steps = findJSONField(digest, 'steps');

  if (!Array.isArray(steps)) {
    return ['the plan lists no steps'];
  }

  const holds = steps.flatMap((step: unknown) => collectStepHolds(step));

  if (findJSONField(digest, 'maybeCorrupt') === true) {
    holds.push('the plan marks a resource as maybe corrupt');
  }

  return [...holds, ...collectSummaryHolds(findJSONField(digest, 'changeSummary'))];
}

// a refresh is not a change, and the drift check reports what it finds; read is a data source
const unattendedOps = new Set(['same', 'create', 'update', 'refresh', 'read']);

// the whole tailnet policy file, the VM and the cloud firewall in front of it
const guardedTypes = new Set([
  'tailscale:index/acl:Acl',
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

  if (!unattendedOps.has(op)) {
    return [`${op} ${urn}`];
  }

  if (changeOps.has(op) && guardedTypes.has(getURNType(urn))) {
    return [`${op} of a guarded resource ${urn}`];
  }

  return [];
}

// urn:pulumi:<stack>::<project>::<parent types and the type, joined by $>::<name>
function getURNType(urn: string): string {
  const qualifiedType = urn.split('::')[2] ?? '';

  return qualifiedType.split('$').at(-1) ?? '';
}

function collectSummaryHolds(summary: unknown): string[] {
  if (typeof summary !== 'object' || summary === null) {
    return [];
  }

  return Object.entries(summary)
    .filter((entry: Readonly<[string, unknown]>) => !unattendedOps.has(entry[0]) && entry[1] !== 0)
    .map(
      (entry: Readonly<[string, unknown]>) =>
        `the plan's summary counts ${String(entry[1])} ${entry[0]}`,
    );
}
