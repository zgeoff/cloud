import type { CommandArgs } from '@pulumi/command/local';
import type { Output } from '@pulumi/pulumi';

export interface NixieSandboxImagesCommandInputs {
  // the Job, as JSON
  readonly job: Output<string>;
  readonly kubeconfig: Output<string>;
}

// Pulumi runs the program from infra/, on the deploy's runner or the owner's machine
const command = 'bun ../scripts/run-sandbox-image-job.ts';

export function buildNixieSandboxImagesCommandArgs(
  inputs: NixieSandboxImagesCommandInputs,
): CommandArgs {
  return {
    // a change to the Job's JSON is an update that runs the Job again; a trigger would replace the
    // Command instead, which the prod deploy's guard holds
    create: command,
    update: command,
    environment: { NIXIE_SANDBOX_IMAGES_JOB: inputs.job },

    // the kubeconfig travels on stdin, so it never reaches a command line or the environment that
    // kubectl's children inherit
    stdin: inputs.kubeconfig,
    addPreviousOutputInEnv: false,
  };
}
