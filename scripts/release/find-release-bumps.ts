import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import type { Runner } from '../run-process.ts';
import { collectPinFiles } from './collect-pin-files.ts';
import { findNewestRelease } from './find-newest-release.ts';
import { findPinnedVersions } from './find-pinned-versions.ts';
import { isNewerVersion } from './is-newer-version.ts';
import { parseReleaseVersion } from './parse-release-version.ts';
import { readReleaseTags } from './read-release-tags.ts';
import type { ReleaseRecord } from './release-registry.ts';
import { releaseRegistry } from './release-registry.ts';

// the workflow that publishes a published-images record's images opens its pull request
const checkedRecords = releaseRegistry.filter(
  (record) => record.source.kind !== 'published-images',
);

export async function findReleaseBumps(
  root: string,
  run: Runner,
): Promise<readonly string[] | Error> {
  const pins = await loadAllPinnedVersions(root);

  if (pins instanceof Error) {
    return pins;
  }

  const lines: string[] = [];

  for (const [index, record] of checkedRecords.entries()) {
    const line = await findRecordBump(run, record, pins[index] ?? []);

    if (line instanceof Error) {
      return line;
    }

    lines.push(...(line === null ? [] : [line]));
  }

  return lines;
}

async function loadAllPinnedVersions(root: string) {
  const pins: (readonly string[])[] = [];

  for (const record of checkedRecords) {
    const files = await loadFiles(root, collectPinFiles(record));

    const pinned = findPinnedVersions(record, files);

    if (pinned instanceof Error) {
      return pinned;
    }

    pins.push(pinned);
  }

  return pins;
}

async function findRecordBump(run: Runner, record: ReleaseRecord, pinned: readonly string[]) {
  const newest = await readNewest(run, record.repo, record.tagPrefix);

  if (newest instanceof Error) {
    return newest;
  }

  return pinned.some((each) => isOlder(each, newest))
    ? [record.name, newest, ...pinned].join(' ')
    : null;
}

async function loadFiles(root: string, paths: readonly string[]) {
  const entries = await Promise.all(
    paths.map(async (path) => {
      const contents = await readFile(join(root, path), 'utf8').catch(() => null);

      return contents === null ? [] : [[path, contents] as const];
    }),
  );

  return Object.fromEntries(entries.flat());
}

async function readNewest(run: Runner, repo: string, prefix: string) {
  const tags = await readReleaseTags(run, repo);

  const newest = tags instanceof Error ? undefined : findNewestRelease(tags, prefix);

  if (tags instanceof Error) {
    return tags;
  }

  return newest ?? new Error(`${repo} has no release tagged ${prefix}X.Y.Z`);
}

function isOlder(pinned: string, newest: string) {
  const held = parseReleaseVersion(pinned);
  const target = parseReleaseVersion(newest);

  return held !== undefined && target !== undefined && isNewerVersion(target, held);
}
