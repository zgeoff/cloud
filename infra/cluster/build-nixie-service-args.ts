import type { ServiceArgs } from '@pulumi/kubernetes/core/v1';
import type { Output } from '@pulumi/pulumi';

export interface NixieServiceInputs {
  readonly name: string;
  readonly namespace: Output<string>;
  readonly labels: Record<string, string>;
  readonly port: number;
}

// A Service for nixie or its web client. Pulumi skips its wait for ready pods: the StatefulSet
// updates after the Service it names, so that wait would hold back the rollout that brings them
// (docs/architecture/workloads/nixie.md).
export function buildNixieServiceArgs(inputs: NixieServiceInputs): ServiceArgs {
  return {
    metadata: {
      name: inputs.name,
      namespace: inputs.namespace,
      annotations: { 'pulumi.com/skipAwait': 'true' },
    },
    spec: {
      selector: inputs.labels,
      ports: [{ name: 'http', port: inputs.port, targetPort: 'http' }],
    },
  };
}
