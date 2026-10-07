import { secret } from '@pulumi/pulumi';
import type { Output } from '@pulumi/pulumi';

interface HealthCheckBindingInputs {
  // the R2 bucket that holds the check's state
  readonly stateBucket: Output<string>;
  readonly targets: readonly { readonly name: string; readonly url: string }[];
  readonly alertURL: string | undefined;
}

type HealthCheckBinding =
  | { readonly name: string; readonly type: 'r2_bucket'; readonly bucketName: Output<string> }
  | { readonly name: string; readonly type: 'plain_text'; readonly text: string }
  | { readonly name: string; readonly type: 'secret_text'; readonly text: Output<string> };

// The health-check Worker's bindings: its state bucket, its targets as JSON, and the
// alert webhook as a secret only when one is set, so an unset or empty URL leaves the
// Worker without ALERT_URL and it alerts nowhere
export function buildHealthCheckBindings(inputs: HealthCheckBindingInputs): HealthCheckBinding[] {
  return [
    { name: 'STATE', type: 'r2_bucket', bucketName: inputs.stateBucket },
    { name: 'TARGETS', type: 'plain_text', text: JSON.stringify(inputs.targets) },
    ...(inputs.alertURL === undefined || inputs.alertURL === ''
      ? []
      : [{ name: 'ALERT_URL', type: 'secret_text', text: secret(inputs.alertURL) } as const]),
  ];
}
