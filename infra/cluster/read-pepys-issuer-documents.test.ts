import { expect, test } from 'bun:test';
import { readPepysIssuerDocuments } from './read-pepys-issuer-documents.ts';

test('it gives the ConfigMap each trust document in deploy/pepys/imp-issuers, byte for byte', async () => {
  const document = await Bun.file(
    new URL('../../deploy/pepys/imp-issuers/geoffcloud.json', import.meta.url),
  ).text();

  expect(readPepysIssuerDocuments()).toStrictEqual({ 'geoffcloud.json': document });
});
