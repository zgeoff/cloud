import { expect, onTestFinished, test } from 'bun:test';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { loadGateManifest } from './load-gate-manifest.ts';

async function setupTest() {
  const directory = await mkdtemp(join(tmpdir(), 'load-gate-manifest-'));

  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  return { directory };
}

test('it reads each gate with its paths, its ignore globs and its skipped line', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.directory, 'gates.yml'),
    [
      'gates:',
      '  lint:',
      '    skipped: Only Markdown changed.',
      "    paths: ['**']",
      "    ignore: ['**/*.md']",
      '  go:',
      '    paths: [provider/**, scripts/check.sh]',
      '',
    ].join('\n'),
  );

  const manifest = await loadGateManifest(join(ctx.directory, 'gates.yml'));

  expect(manifest).toStrictEqual(
    new Map([
      [
        'lint',
        { name: 'lint', paths: ['**'], ignore: ['**/*.md'], skipped: 'Only Markdown changed.' },
      ],
      [
        'go',
        { name: 'go', paths: ['provider/**', 'scripts/check.sh'], ignore: [], skipped: undefined },
      ],
    ]),
  );
});

test.each([
  ['a file with no gates', 'paths: [a/**]\n', ' holds no gates'],
  ['a key beside the gates', 'gates:\n  go:\n    paths: [a/**]\nextra: 1\n', ': unknown key extra'],
  ['a gate that is not a mapping', 'gates:\n  go: [a/**]\n', ': gate go is not a mapping'],
  [
    'a gate with no paths',
    'gates:\n  go:\n    ignore: [a/**]\n',
    ': gate go: paths is not a list of globs',
  ],
  [
    'a gate with an empty paths list',
    'gates:\n  go:\n    paths: []\n',
    ': gate go: paths is not a list of globs',
  ],
  ['a misspelt key in a gate', 'gates:\n  go:\n    path: [a/**]\n', ': gate go: unknown key path'],
  [
    'a glob that is not a string',
    'gates:\n  go:\n    paths: [1]\n',
    ': gate go: paths holds 1, which is not a glob',
  ],
  [
    'an empty ignore glob',
    "gates:\n  go:\n    paths: [a/**]\n    ignore: ['']\n",
    ': gate go: ignore holds "", which is not a glob',
  ],
  [
    'an empty skipped line',
    "gates:\n  go:\n    paths: [a/**]\n    skipped: ''\n",
    ': gate go: skipped is not a line of text',
  ],
])('it rejects %s', async (_label, text, suffix) => {
  const ctx = await setupTest();

  await writeFile(join(ctx.directory, 'gates.yml'), text);

  expect(loadGateManifest(join(ctx.directory, 'gates.yml'))).rejects.toThrowWithMessage(
    Error,
    `${join(ctx.directory, 'gates.yml')}${suffix}`,
  );
});
