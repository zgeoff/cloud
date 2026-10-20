import type { Runner } from '../run-process.ts';
import type { ReleaseValues } from './plan-pin-edits.ts';
import { readImageDigestValues } from './read-image-digest-values.ts';
import { readNPMTarballValues } from './read-npm-tarball-values.ts';
import { readReleaseNotesValues } from './read-release-notes-values.ts';
import type { ReleaseRecord } from './release-registry.ts';
import { runChecked } from './run-checked.ts';

export interface ReleaseRead {
  readonly record: ReleaseRecord;
  readonly version: string;

  readonly pinned: readonly string[];
  readonly run: Runner;
}

export interface ReleaseReadResult {
  readonly values: ReleaseValues;

  readonly flags: readonly string[];
}

export function readReleaseValues(read: ReleaseRead): Promise<ReleaseReadResult | Error> {
  const source = read.record.source;

  return readSourceValues(source.kind, read, source);
}

type ReleaseSource = ReleaseRecord['source'];

type SourceByKind = {
  readonly [Kind in ReleaseSource['kind']]: Extract<ReleaseSource, { kind: Kind }>;
};

type SourceReaders = {
  readonly [Kind in keyof SourceByKind]: (
    read: ReleaseRead,
    source: SourceByKind[Kind],
  ) => Promise<ReleaseReadResult | Error>;
};

// the release workflows run without node_modules, so a keyed record stands in for ts-pattern's
// match
const sourceReaders: SourceReaders = {
  sha256sums: (read) => readSHA256SumsValues(read),
  'image-digests': (read, source) => readImageDigestValues(read, source.images),
  'release-notes': (read) => readReleaseNotesValues(read),
  'npm-tarball': (read, source) => readNPMTarballValues(read, source.packageName),
  'published-images': (read) =>
    Promise.resolve(
      new Error(
        `${read.record.name} pins images this repository publishes: the workflow that publishes them opens its pull request`,
      ),
    ),
};

// TypeScript pairs each source with its reader only through a kind that is its own type parameter
function readSourceValues<Kind extends keyof SourceByKind>(
  kind: Kind,
  read: ReleaseRead,
  source: SourceByKind[Kind],
): Promise<ReleaseReadResult | Error> {
  // the type check refuses a kind with no reader, so only a registry built outside it lands here
  const reader: SourceReaders[Kind] | undefined = sourceReaders[kind];

  return reader === undefined
    ? Promise.resolve(new Error('the registry names a release source kind that no reader reads'))
    : reader(read, source);
}

async function readSHA256SumsValues(read: ReleaseRead): Promise<ReleaseReadResult | Error> {
  const sums = await runChecked(read.run, [
    'gh',
    'release',
    'download',
    `${read.record.tagPrefix}${read.version}`,
    '-R',
    read.record.repo,
    '-p',
    'SHA256SUMS',
    '-O',
    '-',
  ]);

  return sums instanceof Error ? sums : { values: { sha256sums: sums }, flags: [] };
}
