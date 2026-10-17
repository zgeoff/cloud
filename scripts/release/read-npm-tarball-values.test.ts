import { expect, test } from 'bun:test';
import { HttpResponse, http } from 'msw';
import { server } from '../mocks/node.ts';
import { buildStubRunner } from '../test-utils/build-stub-runner.ts';
import { getReleaseRecord } from '../test-utils/get-release-record.ts';
import { readNPMTarballValues } from './read-npm-tarball-values.ts';

test('it fails without a tarball read when npm lacks the version', async () => {
  const stub = buildStubRunner();

  server.use(
    http.get('https://registry.npmjs.org/auto-mode/2.1.0', () =>
      HttpResponse.json({ error: 'version not found: 2.1.0' }, { status: 404 }),
    ),
  );

  const read = await readNPMTarballValues(
    { record: getReleaseRecord('auto-mode'), version: '2.1.0', pinned: ['2.0.0'], run: stub.run },
    'auto-mode',
  );

  expect(read).toStrictEqual(
    new Error('the npm registry answered 404 for https://registry.npmjs.org/auto-mode/2.1.0'),
  );
});

test('it refuses a tarball away from where the agent image fetches it', async () => {
  const stub = buildStubRunner();

  server.use(
    http.get('https://registry.npmjs.org/auto-mode/2.1.0', () =>
      HttpResponse.json({
        name: 'auto-mode',
        version: '2.1.0',
        dist: {
          tarball: 'https://mirror.example.invalid/auto-mode-2.1.0.tgz',
          integrity: `sha512-${'A'.repeat(86)}==`,
        },
      }),
    ),
  );

  const read = await readNPMTarballValues(
    { record: getReleaseRecord('auto-mode'), version: '2.1.0', pinned: ['2.0.0'], run: stub.run },
    'auto-mode',
  );

  expect(read).toStrictEqual(
    new Error(
      "npm lists auto-mode 2.1.0's tarball at https://mirror.example.invalid/auto-mode-2.1.0.tgz, not where the agent image fetches it",
    ),
  );
});

test('it refuses a tarball that does not match its dist integrity', async () => {
  const stub = buildStubRunner();

  server.use(
    http.get('https://registry.npmjs.org/auto-mode/2.1.0', () =>
      HttpResponse.json({
        name: 'auto-mode',
        version: '2.1.0',
        dist: {
          tarball: 'https://registry.npmjs.org/auto-mode/-/auto-mode-2.1.0.tgz',
          integrity: `sha512-${'A'.repeat(86)}==`,
        },
      }),
    ),
    http.get(
      'https://registry.npmjs.org/auto-mode/-/auto-mode-2.1.0.tgz',
      () => new HttpResponse(new Uint8Array([1, 2, 3])),
    ),
  );

  const read = await readNPMTarballValues(
    { record: getReleaseRecord('auto-mode'), version: '2.1.0', pinned: ['2.0.0'], run: stub.run },
    'auto-mode',
  );

  expect(read).toStrictEqual(new Error(`the tarball does not match sha512-${'A'.repeat(86)}==`));
});
