import { expect, mock, test } from 'bun:test';
import type { ResourceTransform } from '@pulumi/pulumi';
import invariant from 'tiny-invariant';
import { registerPortForwardGuard } from './register-port-forward-guard.ts';

test("it registers a stack transform that fails a Helm chart's Role granting pods/portforward", () => {
  const register = mock<(transform: ResourceTransform) => void>();

  registerPortForwardGuard(register);

  const transform = register.mock.calls[0]?.[0];

  invariant(transform);

  expect(register).toHaveBeenCalledOnce();

  expect(() =>
    transform({
      custom: true,
      type: 'kubernetes:rbac.authorization.k8s.io/v1:Role',
      name: 'traefik:nixie/traefik-forward',
      props: {
        metadata: { name: 'traefik-forward', namespace: 'nixie' },
        rules: [{ apiGroups: [''], resources: ['pods/portforward'], verbs: ['create'] }],
      },
      opts: {},
    }),
  ).toThrowWithMessage(
    Error,
    'kubernetes:rbac.authorization.k8s.io/v1:Role has a rule that covers pods/portforward; no RBAC object may grant pods/portforward',
  );
});

test("it registers a stack transform that lets a Helm chart's Role reading pods through unchanged", () => {
  const register = mock<(transform: ResourceTransform) => void>();

  registerPortForwardGuard(register);

  const transform = register.mock.calls[0]?.[0];

  invariant(transform);

  expect(
    transform({
      custom: true,
      type: 'kubernetes:rbac.authorization.k8s.io/v1:Role',
      name: 'alloy:observability/alloy',
      props: {
        metadata: { name: 'alloy', namespace: 'observability' },
        rules: [{ apiGroups: [''], resources: ['pods'], verbs: ['get', 'list', 'watch'] }],
      },
      opts: {},
    }),
  ).toBeUndefined();
});
