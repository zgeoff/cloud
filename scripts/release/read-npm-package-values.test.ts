import { expect, test } from 'bun:test';
import { HttpResponse, http } from 'msw';
import { server } from '../mocks/node.ts';
import { buildStubRunner } from '../test-utils/build-stub-runner.ts';
import { getReleaseRecord } from '../test-utils/get-release-record.ts';
import { readNPMPackageValues } from './read-npm-package-values.ts';

test('it fails when npm lacks the version', async () => {
  const stub = buildStubRunner();

  server.use(
    http.get('https://registry.npmjs.org/@noslop/cli/0.5.0', () =>
      HttpResponse.json({ error: 'version not found: 0.5.0' }, { status: 404 }),
    ),
  );

  const read = await readNPMPackageValues(
    { record: getReleaseRecord('noslop'), version: '0.5.0', pinned: ['0.4.0'], run: stub.run },
    '@noslop/cli',
  );

  expect(read).toStrictEqual(
    new Error('the npm registry answered 404 for https://registry.npmjs.org/@noslop/cli/0.5.0'),
  );
});

test('it reads no value once npm lists the version', async () => {
  const stub = buildStubRunner();

  server.use(
    http.get('https://registry.npmjs.org/@noslop/cli/0.5.0', () =>
      HttpResponse.json({ name: '@noslop/cli', version: '0.5.0' }),
    ),
  );

  const read = await readNPMPackageValues(
    { record: getReleaseRecord('noslop'), version: '0.5.0', pinned: ['0.4.0'], run: stub.run },
    '@noslop/cli',
  );

  expect(read).toStrictEqual({ values: {}, flags: [] });
  expect(stub.calls).toStrictEqual([]);
});
