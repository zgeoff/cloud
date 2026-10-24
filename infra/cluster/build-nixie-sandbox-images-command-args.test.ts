import { expect, test } from 'bun:test';
import { output, secret } from '@pulumi/pulumi';
import { buildNixieSandboxImagesCommandArgs } from './build-nixie-sandbox-images-command-args.ts';

test('it runs the same Job script on a create and an update, with the Job in the environment and the kubeconfig on stdin', () => {
  const job = output('{"kind":"Job"}');
  const kubeconfig = secret('apiVersion: v1\n');

  expect(buildNixieSandboxImagesCommandArgs({ job, kubeconfig })).toStrictEqual({
    create: 'bun ../scripts/run-sandbox-image-job.ts',
    update: 'bun ../scripts/run-sandbox-image-job.ts',
    environment: { NIXIE_SANDBOX_IMAGES_JOB: job },
    stdin: kubeconfig,
    addPreviousOutputInEnv: false,
  });
});
