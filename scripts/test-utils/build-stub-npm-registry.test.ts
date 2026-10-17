import { expect, test } from 'bun:test';
import { server } from '../mocks/node.ts';
import { buildStubNPMRegistry } from './build-stub-npm-registry.ts';

test('it lists a version with its tarball and its sha512 integrity', async () => {
  server.use(
    ...buildStubNPMRegistry({
      'example-mod': { '1.4.2': { tarball: new TextEncoder().encode('tarball bytes') } },
    }),
  );

  const response = await fetch('https://registry.npmjs.org/example-mod/1.4.2');
  const body: unknown = await response.json();

  expect(body).toStrictEqual({
    name: 'example-mod',
    version: '1.4.2',
    dist: {
      tarball: 'https://registry.npmjs.org/example-mod/-/example-mod-1.4.2.tgz',
      integrity: `sha512-${new Bun.CryptoHasher('sha512').update('tarball bytes').digest('base64')}`,
    },
  });
});

test('it lists the tarball where the scenario says it is', async () => {
  server.use(
    ...buildStubNPMRegistry({
      'example-mod': {
        '1.4.2': {
          tarball: new TextEncoder().encode('tarball bytes'),
          tarballURL: 'https://registry.example.invalid/example-mod-1.4.2.tgz',
        },
      },
    }),
  );

  const response = await fetch('https://registry.npmjs.org/example-mod/1.4.2');
  const body: unknown = await response.json();

  expect(body).toMatchObject({
    dist: { tarball: 'https://registry.example.invalid/example-mod-1.4.2.tgz' },
  });
});

test('it serves the tarball bytes', async () => {
  server.use(
    ...buildStubNPMRegistry({
      'example-mod': { '1.4.2': { tarball: new TextEncoder().encode('tarball bytes') } },
    }),
  );

  const response = await fetch('https://registry.npmjs.org/example-mod/-/example-mod-1.4.2.tgz');
  const body = await response.text();

  expect(body).toBe('tarball bytes');
});

test('it answers 404 for a version it lacks', async () => {
  server.use(...buildStubNPMRegistry({}));

  const response = await fetch('https://registry.npmjs.org/example-mod/1.4.2');
  const body: unknown = await response.json();

  expect([response.status, body]).toStrictEqual([404, { error: 'version not found: 1.4.2' }]);
});
