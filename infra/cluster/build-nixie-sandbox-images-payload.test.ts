import { expect, test } from 'bun:test';
import { nixieSandboxImagesPayloadSchema } from '@zgeoff/cloud-topology';
import { buildNixieSandboxImagesJob } from './build-nixie-sandbox-images-job.ts';
import { buildNixieSandboxImagesPayload } from './build-nixie-sandbox-images-payload.ts';

test("it names the ConfigMap and the script key that the Job's script volume mounts, beside the Job's JSON", () => {
  const inputs = {
    image:
      'ghcr.io/zgeoff/nixie:0.43.0@sha256:06d8802f4aac382106d53be0915887e86e36c6960e2404e19af6611a4c01b309',
    secret: 'nixie-secrets-test',
  };

  expect(buildNixieSandboxImagesPayload(inputs)).toStrictEqual({
    namespace: 'nixie',
    configMap: 'nixie-sandbox-images',
    scriptKey: 'add-sandbox-images.js',
    job: JSON.stringify(buildNixieSandboxImagesJob(inputs)),
  });
});

test('it builds a payload that the parser on the runner accepts', () => {
  const payload = buildNixieSandboxImagesPayload({
    image:
      'ghcr.io/zgeoff/nixie:0.43.0@sha256:06d8802f4aac382106d53be0915887e86e36c6960e2404e19af6611a4c01b309',
    secret: 'nixie-secrets-test',
  });

  expect(nixieSandboxImagesPayloadSchema.safeParse(payload).success).toBeTrue();
});
