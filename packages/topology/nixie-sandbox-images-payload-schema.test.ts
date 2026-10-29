import { expect, test } from 'bun:test';
import { nixieSandboxImagesPayloadSchema } from './nixie-sandbox-images-payload-schema.ts';

test('it accepts a payload as given', () => {
  const payload = {
    namespace: 'nixie',
    configMap: 'nixie-sandbox-images',
    scriptKey: 'add-sandbox-images.js',
    job: '{"kind":"Job"}',
  };

  expect(nixieSandboxImagesPayloadSchema.safeParse(payload).data).toStrictEqual(payload);
});

test('it refuses a payload whose Job is an object rather than its JSON', () => {
  const result = nixieSandboxImagesPayloadSchema.safeParse({
    namespace: 'nixie',
    configMap: 'nixie-sandbox-images',
    scriptKey: 'add-sandbox-images.js',
    job: { kind: 'Job' },
  });

  expect(result.error?.issues).toPartiallyContain({ path: ['job'] });
});

test('it refuses a payload with a field the parser does not read', () => {
  const result = nixieSandboxImagesPayloadSchema.safeParse({
    namespace: 'nixie',
    configMap: 'nixie-sandbox-images',
    scriptKey: 'add-sandbox-images.js',
    job: '{"kind":"Job"}',
    image: 'ghcr.io/zgeoff/nixie:0.43.0',
  });

  expect(result.error?.issues).toPartiallyContain({ code: 'unrecognized_keys' });
});
