// Refuses an RBAC object, a Helm chart's included, that grants a port-forward: one reaches a pod
// from 127.0.0.1, which the atc gateway trusts. It covers every namespace and fails
// closed, so a rule or a reference it cannot read, such as an unresolved Output, counts as a grant.
export function requireNoPortForwardGrant(type: string, props: unknown): void {
  if (!isRBACType(type)) {
    return;
  }

  const reason = findPortForwardGrant(props);

  if (reason !== undefined) {
    throw new Error(`${type} ${reason}; no RBAC object may grant pods/portforward`);
  }
}

// a Role or ClusterRole, a binding, or a patch of one, at any RBAC API version
const rbacTypePattern =
  /^kubernetes:rbac\.authorization\.k8s\.io\/[^:]+:(?:Cluster)?Role(?:Binding)?(?:Patch)?$/u;

function isRBACType(type: string): boolean {
  return rbacTypePattern.test(type);
}

function findPortForwardGrant(props: unknown): string | undefined {
  if (!isRecord(props)) {
    return 'has no properties to read';
  }

  if (props['aggregationRule'] !== undefined) {
    return 'aggregates other roles, whose rules the program cannot read';
  }

  if (props['roleRef'] !== undefined) {
    return findBindingGrant(props['roleRef']);
  }

  const rules = props['rules'];

  if (rules === undefined) {
    return undefined;
  }

  if (!Array.isArray(rules)) {
    return 'has rules the program cannot read';
  }

  return rules.some((rule: unknown) => isPortForwardRule(rule))
    ? 'has a rule that covers pods/portforward'
    : undefined;
}

// the built-in ClusterRoles that grant pods/portforward, which a binding must never name
const portForwardClusterRoles = new Set([
  'cluster-admin',
  'admin',
  'edit',
  'system:aggregate-to-edit',
]);

function findBindingGrant(roleRef: unknown): string | undefined {
  if (!isRecord(roleRef) || typeof roleRef['name'] !== 'string') {
    return 'binds a role the program cannot read';
  }

  return roleRef['kind'] === 'ClusterRole' && portForwardClusterRoles.has(roleRef['name'])
    ? `binds the ClusterRole ${roleRef['name']}, which grants pods/portforward`
    : undefined;
}

// any verb counts: a port-forward is a create, and the WebSocket form opens with a get
function isPortForwardRule(rule: unknown): boolean {
  if (!isRecord(rule)) {
    return true;
  }

  // a rule of nonResourceURLs alone, such as /metrics, names no resource
  if (rule['resources'] === undefined && rule['nonResourceURLs'] !== undefined) {
    return false;
  }

  return (
    isListCovering(rule['apiGroups'], ['', '*']) &&
    isListCovering(rule['resources'], ['pods/portforward', 'pods/*', '*'])
  );
}

// a list that names one of the values, or that the program cannot read
function isListCovering(list: unknown, values: readonly string[]): boolean {
  if (!Array.isArray(list)) {
    return true;
  }

  return list.some((item: unknown) => typeof item !== 'string' || values.includes(item));
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}
