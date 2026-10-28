import type { Provider } from '@pulumi/kubernetes';
import { NetworkPolicy } from '@pulumi/kubernetes/networking/v1';
import type { Input } from '@pulumi/pulumi';
import {
  buildEgressDenyNetworkPolicySpec,
  egressDenyPolicyName,
} from './build-egress-deny-network-policy-spec.ts';
import type { ClusterNamespace } from './cluster-namespaces.ts';

export function createEgressDeny(
  name: ClusterNamespace,
  namespace: Input<string>,
  cluster: Provider,
): NetworkPolicy {
  return new NetworkPolicy(
    `${name}-${egressDenyPolicyName}`,
    {
      metadata: { name: egressDenyPolicyName, namespace },
      spec: buildEgressDenyNetworkPolicySpec(),
    },
    { provider: cluster },
  );
}
