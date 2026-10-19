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

type ReleaseSource = ReleaseRecord['source'];

type SourceReader<Source extends ReleaseSource> = (
  read: ReleaseRead,
  source: Source,
) => Promise<ReleaseReadResult | Error>;

const sourceReaders: {
  readonly [Kind in ReleaseSource['kind']]: SourceReader<Extract<ReleaseSource, { kind: Kind }>>;
} = {
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

export function readReleaseValues(read: ReleaseRead): Promise<ReleaseReadResult | Error> {
  const source = read.record.source;

  // the release workflows run without node_modules, so a keyed record stands in for ts-pattern's
  // match
  // oxlint-disable-next-line typescript/no-unsafe-type-assertion -- the entry for source.kind reads that kind
  const reader = sourceReaders[source.kind] as SourceReader<typeof source> | undefined;

  // the type check refuses a kind with no reader, so only a registry built outside it lands here
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
