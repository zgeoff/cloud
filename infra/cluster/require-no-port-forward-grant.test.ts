import { expect, test } from 'bun:test';
import { output } from '@pulumi/pulumi';
import { requireNoPortForwardGrant } from './require-no-port-forward-grant.ts';

test.each([
  [
    'a ClusterRole that reads pods and their logs',
    'kubernetes:rbac.authorization.k8s.io/v1:ClusterRole',
    {
      metadata: { name: 'alloy' },
      rules: [
        { apiGroups: [''], resources: ['pods', 'pods/log'], verbs: ['get', 'list', 'watch'] },
      ],
    },
  ],
  [
    'a ClusterRole that grants every verb in another API group',
    'kubernetes:rbac.authorization.k8s.io/v1:ClusterRole',
    { rules: [{ apiGroups: ['monitoring.coreos.com'], resources: ['*'], verbs: ['*'] }] },
  ],
  [
    'a ClusterRole that reads /metrics',
    'kubernetes:rbac.authorization.k8s.io/v1:ClusterRole',
    { rules: [{ nonResourceURLs: ['/metrics'], verbs: ['get'] }] },
  ],
  [
    'a Role with no rules',
    'kubernetes:rbac.authorization.k8s.io/v1:Role',
    { metadata: { name: 'empty', namespace: 'atc' } },
  ],
  [
    "a RoleBinding to the chart's own ClusterRole",
    'kubernetes:rbac.authorization.k8s.io/v1:RoleBinding',
    {
      roleRef: { apiGroup: 'rbac.authorization.k8s.io', kind: 'ClusterRole', name: 'traefik' },
      subjects: [{ kind: 'ServiceAccount', name: 'traefik', namespace: 'nixie' }],
    },
  ],
  [
    'a RoleBinding to a Role that happens to be named admin',
    'kubernetes:rbac.authorization.k8s.io/v1:RoleBinding',
    { roleRef: { apiGroup: 'rbac.authorization.k8s.io', kind: 'Role', name: 'admin' } },
  ],
  [
    'a Secret, which is not RBAC',
    'kubernetes:core/v1:Secret',
    { rules: [{ apiGroups: [''], resources: ['pods/portforward'], verbs: ['create'] }] },
  ],
])('it allows %s', (_label: string, type: string, props: unknown) => {
  expect(() => {
    requireNoPortForwardGrant(type, props);
  }).not.toThrow();
});

test.each([
  [
    'a Role that grants pods/portforward',
    'kubernetes:rbac.authorization.k8s.io/v1:Role',
    { rules: [{ apiGroups: [''], resources: ['pods/portforward'], verbs: ['create'] }] },
    'has a rule that covers pods/portforward',
  ],
  [
    'a Role that grants only get on pods/portforward',
    'kubernetes:rbac.authorization.k8s.io/v1:Role',
    { rules: [{ apiGroups: [''], resources: ['pods/portforward'], verbs: ['get'] }] },
    'has a rule that covers pods/portforward',
  ],
  [
    "a ClusterRole that grants every pod's subresource",
    'kubernetes:rbac.authorization.k8s.io/v1:ClusterRole',
    { rules: [{ apiGroups: [''], resources: ['pods/*'], verbs: ['*'] }] },
    'has a rule that covers pods/portforward',
  ],
  [
    'a ClusterRole that grants every resource in every API group',
    'kubernetes:rbac.authorization.k8s.io/v1:ClusterRole',
    { rules: [{ apiGroups: ['*'], resources: ['*'], verbs: ['get'] }] },
    'has a rule that covers pods/portforward',
  ],
  [
    'a ClusterRolePatch that adds pods/portforward',
    'kubernetes:rbac.authorization.k8s.io/v1:ClusterRolePatch',
    { rules: [{ apiGroups: [''], resources: ['pods/portforward'], verbs: ['create'] }] },
    'has a rule that covers pods/portforward',
  ],
  [
    'a Role at an older API version',
    'kubernetes:rbac.authorization.k8s.io/v1beta1:Role',
    { rules: [{ apiGroups: [''], resources: ['pods/portforward'], verbs: ['create'] }] },
    'has a rule that covers pods/portforward',
  ],
  [
    'a rule whose resources are an unresolved Output',
    'kubernetes:rbac.authorization.k8s.io/v1:Role',
    { rules: [{ apiGroups: [''], resources: output(['pods']), verbs: ['get'] }] },
    'has a rule that covers pods/portforward',
  ],
  [
    'rules that are an unresolved Output',
    'kubernetes:rbac.authorization.k8s.io/v1:Role',
    { rules: output([]) },
    'has rules the program cannot read',
  ],
  [
    'a ClusterRole that aggregates other roles',
    'kubernetes:rbac.authorization.k8s.io/v1:ClusterRole',
    { aggregationRule: { clusterRoleSelectors: [{ matchLabels: { aggregate: 'true' } }] } },
    'aggregates other roles, whose rules the program cannot read',
  ],
  [
    'a RoleBinding to the built-in edit ClusterRole',
    'kubernetes:rbac.authorization.k8s.io/v1:RoleBinding',
    { roleRef: { apiGroup: 'rbac.authorization.k8s.io', kind: 'ClusterRole', name: 'edit' } },
    'binds the ClusterRole edit, which grants pods/portforward',
  ],
  [
    'a RoleBinding to the built-in admin ClusterRole',
    'kubernetes:rbac.authorization.k8s.io/v1:RoleBinding',
    { roleRef: { apiGroup: 'rbac.authorization.k8s.io', kind: 'ClusterRole', name: 'admin' } },
    'binds the ClusterRole admin, which grants pods/portforward',
  ],
  [
    'a ClusterRoleBinding to cluster-admin',
    'kubernetes:rbac.authorization.k8s.io/v1:ClusterRoleBinding',
    {
      roleRef: {
        apiGroup: 'rbac.authorization.k8s.io',
        kind: 'ClusterRole',
        name: 'cluster-admin',
      },
    },
    'binds the ClusterRole cluster-admin, which grants pods/portforward',
  ],
  [
    'a ClusterRoleBinding to the role that edit aggregates',
    'kubernetes:rbac.authorization.k8s.io/v1:ClusterRoleBinding',
    {
      roleRef: {
        apiGroup: 'rbac.authorization.k8s.io',
        kind: 'ClusterRole',
        name: 'system:aggregate-to-edit',
      },
    },
    'binds the ClusterRole system:aggregate-to-edit, which grants pods/portforward',
  ],
  [
    'a binding whose role name is an unresolved Output',
    'kubernetes:rbac.authorization.k8s.io/v1:RoleBinding',
    { roleRef: { apiGroup: 'rbac.authorization.k8s.io', kind: 'ClusterRole', name: output('x') } },
    'binds a role the program cannot read',
  ],
])('it refuses %s', (_label: string, type: string, props: unknown, reason: string) => {
  expect(() => {
    requireNoPortForwardGrant(type, props);
  }).toThrowWithMessage(
    Error,
    `${type} ${reason}; no RBAC object may grant pods/portforward (GEO-1388)`,
  );
});
