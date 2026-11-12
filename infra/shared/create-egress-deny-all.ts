import type { Provider } from '@pulumi/kubernetes';
import { NetworkPolicy } from '@pulumi/kubernetes/networking/v1';
import type { Input } from '@pulumi/pulumi';
import {
  buildEgressDenyAllNetworkPolicySpec,
  egressDenyAllPolicyName,
} from './build-egress-deny-all-network-policy-spec.ts';
import type { ClusterNamespace } from './cluster-namespaces.ts';

export function createEgressDenyAll(
  name: ClusterNamespace,
  namespace: Input<string>,
  cluster: Provider,
): NetworkPolicy {
  return new NetworkPolicy(
    `${name}-${egressDenyAllPolicyName}`,
    {
      metadata: { name: egressDenyAllPolicyName, namespace },
      spec: buildEgressDenyAllNetworkPolicySpec(),
    },
    { provider: cluster },
  );
}
