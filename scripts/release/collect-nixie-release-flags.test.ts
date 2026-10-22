import { expect, test } from 'bun:test';
import { collectNixieReleaseFlags } from './collect-nixie-release-flags.ts';

test('it flags nothing for a release without migrations', () => {
  expect(
    collectNixieReleaseFlags({
      target:
        '## Changes\n\n- a fix\n\n## Migrations\n\nThis release adds no migration since v0.31.0.\n\n## Images\n\n- `ghcr.io/zgeoff/nixie@sha256:ccc`\n- `ghcr.io/zgeoff/sandbox-node@sha256:bbb`\n',
      between: [],
    }),
  ).toStrictEqual([]);
});

test('it flags nothing for a release whose notes mark each section with an HTML comment', () => {
  expect(
    collectNixieReleaseFlags({
      target:
        "## [0.20.1](https://example.com/compare/v0.20.0...v0.20.1) (2026-01-02)\n\n\n### Bug Fixes\n\n* **geo-1:** a fix\n\n<!-- nixie: migrations -->\n## Migrations\n\nThis release adds no migration since v0.20.0.\n\n<!-- nixie: config schema -->\n## Config schema\n\nEvery config.yaml that v0.20.0 accepts passes this release's config.schema.json.\n\n## Images\n\n- `ghcr.io/zgeoff/nixie@sha256:ccc`\n- `ghcr.io/zgeoff/sandbox-node@sha256:bbb`\n",
      between: [],
    }),
  ).toStrictEqual([]);
});

test('it flags migrations in notes that mark each section with an HTML comment', () => {
  expect(
    collectNixieReleaseFlags({
      target:
        "<!-- nixie: migrations -->\n## Migrations\n\n- 0012 adds the labels table\n\n<!-- nixie: config schema -->\n## Config schema\n\nEvery config.yaml that v0.20.0 accepts passes this release's config.schema.json.\n\n## Images\n",
      between: [],
    }),
  ).toStrictEqual(['migrations']);
});

test('it flags migrations that the target adds', () => {
  expect(
    collectNixieReleaseFlags({
      target: '## Migrations\n\n- 0007 adds the drafts table\n\n## Images\n',
      between: [],
    }),
  ).toStrictEqual(['migrations']);
});

test('it flags migrations that only a release between adds', () => {
  expect(
    collectNixieReleaseFlags({
      target: '## Migrations\n\nThis release adds no migration since v0.31.1.\n\n## Images\n',
      between: ['## Migrations\n\n- 0008 renames a column\n'],
    }),
  ).toStrictEqual(['migrations']);
});

test('it flags migrations when a release lacks the section', () => {
  expect(
    collectNixieReleaseFlags({
      target: '## Changes\n\n- a fix\n\n## Images\n',
      between: [],
    }),
  ).toStrictEqual(['migrations']);
});

test('it flags migrations when the section is blank', () => {
  expect(
    collectNixieReleaseFlags({
      target: '## Migrations\n\n\n## Images\n',
      between: [],
    }),
  ).toStrictEqual(['migrations']);
});

test('it flags migrations in a section longer than a pipe buffer', () => {
  const long = Array.from({ length: 4000 }, (_, index) => `- ${index} adds a column`).join('\n');

  expect(
    collectNixieReleaseFlags({
      target: `## Migrations\n\n${long}\n\n## Images\n`,
      between: [],
    }),
  ).toStrictEqual(['migrations']);
});

test('it flags nothing for a release whose sandbox images changed, because nixie adds its own images', () => {
  expect(
    collectNixieReleaseFlags({
      target:
        '## Migrations\n\nThis release adds no migration since v0.31.0.\n\n## Images\n\n- `ghcr.io/zgeoff/nixie@sha256:ccc`\n- `ghcr.io/zgeoff/nixie-web@sha256:eee`\n- `ghcr.io/zgeoff/sandbox-node@sha256:fff`\n',
      between: [],
    }),
  ).toStrictEqual([]);
});
