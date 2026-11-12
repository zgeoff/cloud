import { expect, onTestFinished, test } from 'bun:test';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { readBoxxyTrustDocuments } from './read-boxxy-trust-documents.ts';

async function setupTest(): Promise<string> {
  const folder = await mkdtemp(join(tmpdir(), 'boxxy-issuers-'));

  onTestFinished(async () => {
    await rm(folder, { recursive: true, force: true });
  });

  return folder;
}

test('it returns each JSON file of the folder by name, in name order, and skips other files and folders', async () => {
  const folder = await setupTest();

  await writeFile(join(folder, 'second-host.json'), '{"issuer":"second-host"}\n');
  await writeFile(join(folder, 'first-host.json'), '{"issuer":"first-host"}\n');
  await writeFile(join(folder, 'README.md'), 'not a document\n');
  await mkdir(join(folder, 'nested.json'));

  expect(readBoxxyTrustDocuments(folder)).toStrictEqual({
    'first-host.json': '{"issuer":"first-host"}\n',
    'second-host.json': '{"issuer":"second-host"}\n',
  });

  expect(Object.keys(readBoxxyTrustDocuments(folder))).toStrictEqual([
    'first-host.json',
    'second-host.json',
  ]);
});

test('it returns no document for a missing folder', async () => {
  const folder = await setupTest();

  expect(readBoxxyTrustDocuments(join(folder, 'missing'))).toStrictEqual({});
});
