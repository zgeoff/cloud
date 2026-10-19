import { secret } from '@pulumi/pulumi';
import type { Output } from '@pulumi/pulumi';
import { bindingNames } from '@zgeoff/cloud-health-check/contract';
import type { Target } from '@zgeoff/cloud-health-check/contract';

interface HealthCheckBindingInputs {
  readonly stateBucket: Output<string>;
  readonly targets: readonly Target[];

  // checked by the inputs group: trimmed, and undefined when unset or blank
  readonly alertURL: string | undefined;
}

type HealthCheckBinding =
  | { readonly name: string; readonly type: 'r2_bucket'; readonly bucketName: Output<string> }
  | { readonly name: string; readonly type: 'plain_text'; readonly text: string }
  | { readonly name: string; readonly type: 'secret_text'; readonly text: Output<string> };

export function buildHealthCheckBindings(inputs: HealthCheckBindingInputs): HealthCheckBinding[] {
  return [
    { name: bindingNames.state, type: 'r2_bucket', bucketName: inputs.stateBucket },
    { name: bindingNames.targets, type: 'plain_text', text: JSON.stringify(inputs.targets) },
    ...(inputs.alertURL === undefined
      ? []
      : [
          {
            name: bindingNames.alertURL,
            type: 'secret_text',
            text: secret(inputs.alertURL),
          } as const,
        ]),
  ];
}
