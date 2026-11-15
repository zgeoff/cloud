import type { ServiceAccountArgs } from '@pulumi/kubernetes/core/v1';
import type { RoleArgs, RoleBindingArgs } from '@pulumi/kubernetes/rbac/v1';
import type { Output } from '@pulumi/pulumi';

const nixieVerifyName = 'nixie-verify';

export interface NixieVerifyAccessInputs {
  readonly namespace: Output<string>;
  readonly statefulSet: string;
  readonly service: string;
  readonly servicePort: string;
}

export interface NixieVerifyAccessArgs {
  readonly serviceAccount: ServiceAccountArgs;
  readonly role: RoleArgs;
  readonly roleBinding: RoleBindingArgs;
}

// The account of nixie's prod doctor. The API server strips the caller's credentials before it
// proxies, so a GET through the proxy reaches nixie as an anonymous call.
export function buildNixieVerifyAccessArgs(
  inputs: Readonly<NixieVerifyAccessInputs>,
): NixieVerifyAccessArgs {
  const metadata = { name: nixieVerifyName, namespace: inputs.namespace };

  return {
    // the deploy job and the owner mint its tokens, and no pod runs as it
    serviceAccount: { metadata, automountServiceAccountToken: false },
    role: {
      metadata,
      rules: [
        {
          apiGroups: [''],
          resources: ['pods', 'pods/log'],
          resourceNames: [`${inputs.statefulSet}-0`],
          verbs: ['get'],
        },
        {
          apiGroups: ['apps'],
          resources: ['statefulsets'],
          resourceNames: [inputs.statefulSet],
          verbs: ['get'],
        },
        {
          // the API server authorizes a proxy call by the URL's whole segment, scheme and port
          // included, so the bare Service name would refuse it
          apiGroups: [''],
          resources: ['services/proxy'],
          resourceNames: [`http:${inputs.service}:${inputs.servicePort}`],
          verbs: ['get'],
        },
      ],
    },
    roleBinding: {
      metadata,
      roleRef: { apiGroup: 'rbac.authorization.k8s.io', kind: 'Role', name: nixieVerifyName },
      subjects: [{ kind: 'ServiceAccount', name: nixieVerifyName, namespace: inputs.namespace }],
    },
  };
}
