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

// Reads what the release publishes for its pins, as its record's source kind says
export async function readReleaseValues(read: ReleaseRead): Promise<ReleaseReadResult | Error> {
  const source = read.record.source;

  switch (source.kind) {
    case 'sha256sums': {
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
    case 'image-digests': {
      return readImageDigestValues(read, source.images);
    }
    case 'release-notes': {
      return readReleaseNotesValues(read);
    }
    case 'npm-tarball': {
      return readNPMTarballValues(read, source.packageName);
    }

    // the type check refuses a kind with no case, so only a registry built outside it lands here
    default: {
      return new Error('the registry names a release source kind that no case reads');
    }
  }
}
