import { expect, test } from 'bun:test';
import { output } from '@pulumi/pulumi';
import { buildNixieVerifyAccessArgs } from './build-nixie-verify-access-args.ts';
import { requireNoPortForwardGrant } from './require-no-port-forward-grant.ts';

test("it lets the account only get nixie's pod, its log, its StatefulSet and a proxied GET to the Service's port", () => {
  const namespace = output('nixie');

  expect(
    buildNixieVerifyAccessArgs({
      namespace,
      statefulSet: 'nixie',
      service: 'nixie',
      servicePort: 'http',
    }),
  ).toStrictEqual({
    serviceAccount: {
      metadata: { name: 'nixie-verify', namespace },
      automountServiceAccountToken: false,
    },
    role: {
      metadata: { name: 'nixie-verify', namespace },
      rules: [
        {
          apiGroups: [''],
          resources: ['pods', 'pods/log'],
          resourceNames: ['nixie-0'],
          verbs: ['get'],
        },
        {
          apiGroups: ['apps'],
          resources: ['statefulsets'],
          resourceNames: ['nixie'],
          verbs: ['get'],
        },
        {
          apiGroups: [''],
          resources: ['services/proxy'],
          resourceNames: ['http:nixie:http'],
          verbs: ['get'],
        },
      ],
    },
    roleBinding: {
      metadata: { name: 'nixie-verify', namespace },
      roleRef: { apiGroup: 'rbac.authorization.k8s.io', kind: 'Role', name: 'nixie-verify' },
      subjects: [{ kind: 'ServiceAccount', name: 'nixie-verify', namespace }],
    },
  });
});

test('it builds a Role and a RoleBinding that the port-forward guard passes', () => {
  const access = buildNixieVerifyAccessArgs({
    namespace: output('nixie'),
    statefulSet: 'nixie',
    service: 'nixie',
    servicePort: 'http',
  });

  expect(() => {
    requireNoPortForwardGrant('kubernetes:rbac.authorization.k8s.io/v1:Role', access.role);

    requireNoPortForwardGrant(
      'kubernetes:rbac.authorization.k8s.io/v1:RoleBinding',
      access.roleBinding,
    );
  }).not.toThrow();
});
