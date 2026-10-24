import { expect, test } from 'bun:test';
import { output, secret } from '@pulumi/pulumi';
import { buildNixieSandboxImagesCommandArgs } from './build-nixie-sandbox-images-command-args.ts';

test('it runs the same Job script on a create and an update, with the payload in the environment and the kubeconfig on stdin', () => {
  const payload = output('{"namespace":"nixie"}');
  const kubeconfig = secret('apiVersion: v1\n');

  expect(buildNixieSandboxImagesCommandArgs({ payload, kubeconfig })).toStrictEqual({
    create: 'bun ../scripts/run-sandbox-image-job.ts',
    update: 'bun ../scripts/run-sandbox-image-job.ts',
    environment: { NIXIE_SANDBOX_IMAGES: payload },
    stdin: kubeconfig,
    addPreviousOutputInEnv: false,
  });
});
