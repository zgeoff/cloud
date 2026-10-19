import type { ServiceArgs } from '@pulumi/kubernetes/core/v1';
import type { Output } from '@pulumi/pulumi';

export interface NixieServiceInputs {
  readonly name: string;
  readonly namespace: Output<string>;
  readonly labels: Record<string, string>;
  readonly port: number;
}

export function buildNixieServiceArgs(inputs: NixieServiceInputs): ServiceArgs {
  return {
    metadata: {
      name: inputs.name,
      namespace: inputs.namespace,

      // the StatefulSet updates after the Service it names, so Pulumi's wait for ready pods would
      // hold back the rollout that brings them
      annotations: { 'pulumi.com/skipAwait': 'true' },
    },
    spec: {
      selector: inputs.labels,
      ports: [{ name: 'http', port: inputs.port, targetPort: 'http' }],
    },
  };
}
