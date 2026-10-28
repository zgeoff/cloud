import { NetworkPolicy } from '@pulumi/kubernetes/networking/v1';
import type { CustomResourceOptions, Input } from '@pulumi/pulumi';
import { buildEgressAllowNetworkPolicySpec } from './build-egress-allow-network-policy-spec.ts';
import type { EgressAllow } from './egress-allows.ts';

export function createEgressAllow(
  allow: EgressAllow,
  namespace: Input<string>,
  opts: CustomResourceOptions,
): NetworkPolicy {
  return new NetworkPolicy(
    allow.name,
    {
      metadata: { name: allow.name, namespace },
      spec: buildEgressAllowNetworkPolicySpec(allow),
    },
    opts,
  );
}
