import { expect, test } from 'bun:test';
import { runProcess } from '../run-process.ts';
import { createNPMTarball } from './create-npm-tarball.ts';

test('it packs the manifest as package/package.json in a gzipped tarball', async () => {
  const tarball = await createNPMTarball({ name: 'example-mod', version: '1.4.2' });

  const listed = await runProcess(['tar', '-xzO', '-f', '-', 'package/package.json'], {
    stdin: Buffer.from(tarball),
  });

  expect(listed.stdout.toString()).toBe('{"name":"example-mod","version":"1.4.2"}\n');
});
