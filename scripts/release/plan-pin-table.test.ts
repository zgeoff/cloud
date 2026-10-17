import { expect, test } from 'bun:test';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { getReleaseRecord } from '../test-utils/get-release-record.ts';
import { collectPinFiles } from './collect-pin-files.ts';
import { planPinTable } from './plan-pin-table.ts';
import { releaseRegistry } from './release-registry.ts';

test("it takes the given record's entries and keeps the others in registry order", () => {
  expect(
    planPinTable([getReleaseRecord('nixie')], {
      'scripts/release/release-pins.json': `{\n  "auto-mode": {\n    "version": "0.19.3",\n    "sum": "${'d'.repeat(64)}"\n  },\n  "nixie": {\n    "version": "0.6.2",\n    "digest": "sha256:${'c'.repeat(64)}"\n  }\n}\n`,
      'infra/Pulumi.prod.yaml': `nixie:\n    image: ghcr.io/zgeoff/nixie:0.7.0@sha256:${'a'.repeat(64)}\n    webImage: ghcr.io/zgeoff/nixie-web:0.7.0@sha256:${'b'.repeat(64)}\n`,
    }),
  ).toBe(
    `{\n  "nixie": {\n    "version": "0.7.0",\n    "digest": "sha256:${'a'.repeat(64)}"\n  },\n  "nixie-web": {\n    "version": "0.7.0",\n    "digest": "sha256:${'b'.repeat(64)}"\n  },\n  "auto-mode": {\n    "version": "0.19.3",\n    "sum": "${'d'.repeat(64)}"\n  }\n}\n`,
  );
});

test('it keeps an entry the registry lacks after the registry pins', () => {
  expect(
    planPinTable([getReleaseRecord('auto-mode')], {
      'scripts/release/release-pins.json': '{\n  "retired": {\n    "version": "1.0.0"\n  }\n}\n',
      'images/agent/Dockerfile': `ARG AUTO_MODE_VERSION=0.19.4\nARG AUTO_MODE_SHA256=${'e'.repeat(64)}\n`,
    }),
  ).toBe(
    `{\n  "auto-mode": {\n    "version": "0.19.4",\n    "sum": "${'e'.repeat(64)}"\n  },\n  "retired": {\n    "version": "1.0.0"\n  }\n}\n`,
  );
});

test('it keeps a __proto__ entry the registry lacks', () => {
  expect(
    planPinTable([getReleaseRecord('auto-mode')], {
      'scripts/release/release-pins.json': '{\n  "__proto__": {\n    "version": "1.0.0"\n  }\n}\n',
      'images/agent/Dockerfile': `ARG AUTO_MODE_VERSION=0.19.4\nARG AUTO_MODE_SHA256=${'e'.repeat(64)}\n`,
    }),
  ).toBe(
    `{\n  "auto-mode": {\n    "version": "0.19.4",\n    "sum": "${'e'.repeat(64)}"\n  },\n  "__proto__": {\n    "version": "1.0.0"\n  }\n}\n`,
  );
});

test('it builds every record without a table', async () => {
  const root = join(import.meta.dir, '..', '..');

  const paths = [...new Set(releaseRegistry.flatMap((record) => collectPinFiles(record)))].filter(
    (path) => path !== 'scripts/release/release-pins.json',
  );

  const contents = await Promise.all(paths.map((path) => readFile(join(root, path), 'utf8')));
  const committed = await readFile(join(root, 'scripts/release/release-pins.json'), 'utf8');

  const files = Object.fromEntries(paths.map((path, index) => [path, contents[index] ?? '']));

  expect(planPinTable([], files)).toBe(committed);
});

test('it refuses a table that holds no JSON object', () => {
  expect(
    planPinTable([getReleaseRecord('auto-mode')], {
      'scripts/release/release-pins.json': '["auto-mode"]\n',
      'images/agent/Dockerfile': `ARG AUTO_MODE_VERSION=0.19.4\nARG AUTO_MODE_SHA256=${'e'.repeat(64)}\n`,
    }),
  ).toStrictEqual(new Error('scripts/release/release-pins.json holds no JSON object'));
});

test('it refuses a table that is not JSON', () => {
  expect(
    planPinTable([getReleaseRecord('auto-mode')], {
      'scripts/release/release-pins.json': '{ "auto-mode": \n',
      'images/agent/Dockerfile': `ARG AUTO_MODE_VERSION=0.19.4\nARG AUTO_MODE_SHA256=${'e'.repeat(64)}\n`,
    }),
  ).toStrictEqual(new Error('scripts/release/release-pins.json holds no JSON object'));
});
