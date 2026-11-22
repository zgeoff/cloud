import { expect, test } from 'bun:test';
import { readPepysTrustDocuments } from './read-pepys-trust-documents.ts';

test('it gives the ConfigMap each trust document in deploy/pepys/imp-issuers, byte for byte', async () => {
  const document = await Bun.file(
    new URL('../../deploy/pepys/imp-issuers/geoffcloud.json', import.meta.url),
  ).text();

  expect(readPepysTrustDocuments('imp-issuers')).toStrictEqual({ 'geoffcloud.json': document });
});
