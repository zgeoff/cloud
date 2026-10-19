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

  // the pins' versions on main, in the record's order
  readonly pinned: readonly string[];
  readonly run: Runner;
}

export interface ReleaseReadResult {
  readonly values: ReleaseValues;

  // the review flags that the release's own notes raise
  readonly flags: readonly string[];
}

type ReleaseSource = ReleaseRecord['source'];

type SourceReader<Source extends ReleaseSource> = (
  read: ReleaseRead,
  source: Source,
) => Promise<ReleaseReadResult | Error> | Error;

// One reader per source kind. The release workflows run these scripts without node_modules, so a
// keyed record branches here in place of ts-pattern's match, and its type still needs every kind.
const sourceReaders: {
  readonly [Kind in ReleaseSource['kind']]: SourceReader<Extract<ReleaseSource, { kind: Kind }>>;
} = {
  sha256sums: (read) => readSHA256SumsValues(read),
  'image-digests': (read, source) => readImageDigestValues(read, source.images),
  'release-notes': (read) => readReleaseNotesValues(read),
  'npm-tarball': (read, source) => readNPMTarballValues(read, source.packageName),
  'published-images': (read) =>
    new Error(
      `${read.record.name} pins images this repository publishes: the workflow that publishes them opens its pull request`,
    ),
};

// Reads what the release publishes for its pins, as its record's source kind says
export async function readReleaseValues(read: ReleaseRead): Promise<ReleaseReadResult | Error> {
  const source = read.record.source;
  const reader = sourceReaders[source.kind] as SourceReader<typeof source> | undefined;

  // the type check refuses a kind with no reader, so only a registry built outside it lands here
  if (reader === undefined) {
    return new Error('the registry names a release source kind that no reader reads');
  }

  return await reader(read, source);
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
