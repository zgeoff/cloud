import { findJSONField } from '../find-json-field.ts';
import { collectNixieReleaseFlags } from './collect-nixie-release-flags.ts';
import { isNewerVersion } from './is-newer-version.ts';
import { parseReleaseVersion } from './parse-release-version.ts';
import { readReleaseTags } from './read-release-tags.ts';
import type { ReleaseRead, ReleaseReadResult } from './read-release-values.ts';
import type { ReleaseRecord } from './release-registry.ts';
import { runChecked } from './run-checked.ts';

export async function readReleaseNotesValues(
  read: ReleaseRead,
): Promise<ReleaseReadResult | Error> {
  const versions = await readNoteVersions(read);

  if (versions instanceof Error) {
    return versions;
  }

  const notes = await readAllNotes(read, versions);

  if (notes instanceof Error) {
    return notes;
  }

  const [pinned = '', target = '', ...between] = notes;
  const digests = collectDigests(read.record, target);

  return digests instanceof Error
    ? digests
    : { values: { digests }, flags: collectNixieReleaseFlags({ pinned, target, between }) };
}

async function readNoteVersions(read: ReleaseRead) {
  const prefix = read.record.tagPrefix;

  const tags = await readReleaseTags(read.run, read.record.repo);

  const from = findOldest(read.pinned);

  if (tags instanceof Error) {
    return tags;
  }

  if (from === undefined || !tags.includes(`${prefix}${from}`)) {
    return new Error(
      `the latest 30 ${read.record.name} releases do not reach the pinned ${prefix}${from ?? '?'}, so the releases between go unread`,
    );
  }

  const between = tags
    .map((tag) => tag.slice(prefix.length))
    .filter((each) => tags.includes(`${prefix}${each}`) && isBetween(each, from, read.version));

  return [from, read.version, ...between];
}

function findOldest(pinned: readonly string[]) {
  return pinned.reduce<string | undefined>((oldest, each) => {
    const candidate = parseReleaseVersion(each);
    const best = oldest === undefined ? undefined : parseReleaseVersion(oldest);

    const isOlder =
      candidate !== undefined && (best === undefined || isNewerVersion(best, candidate));

    return isOlder ? each : oldest;
  }, undefined);
}

function isBetween(each: string, from: string, to: string) {
  const version = parseReleaseVersion(each);
  const low = parseReleaseVersion(from);
  const high = parseReleaseVersion(to);

  return (
    version !== undefined &&
    low !== undefined &&
    high !== undefined &&
    isNewerVersion(version, low) &&
    isNewerVersion(high, version)
  );
}

async function readAllNotes(read: ReleaseRead, versions: readonly string[]) {
  const notes: string[] = [];

  for (const version of versions) {
    const tag = `${read.record.tagPrefix}${version}`;

    const viewed = await runChecked(read.run, [
      'gh',
      'release',
      'view',
      tag,
      '-R',
      read.record.repo,
      '--json',
      'body',
    ]);

    if (viewed instanceof Error) {
      return viewed;
    }

    const body = findJSONField(JSON.parse(viewed), 'body');
    const text = typeof body === 'string' ? body : '';

    notes.push(text);
  }

  return notes;
}

function collectDigests(record: ReleaseRecord, target: string) {
  const section = findImagesSection(target);
  const digests: Record<string, string> = {};

  for (const image of collectDigestImages(record)) {
    const reference = `ghcr.io/zgeoff/${image}@`;

    const found = section.flatMap((line) => {
      const digest = /^- `(?<ref>[^`@]+@)(?<digest>sha256:[0-9a-f]{64})`$/u.exec(line)?.groups;
      const value = digest?.['ref'] === reference ? digest['digest'] : undefined;

      return value === undefined ? [] : [value];
    });

    if (found.length !== 1) {
      return new Error(
        `the release notes list ${found.length} ghcr.io/zgeoff/${image} digests under ## Images, want 1`,
      );
    }

    digests[image] = found[0] ?? '';
  }

  return digests;
}

function findImagesSection(notes: string) {
  const lines = notes.split('\n');
  const rest = lines.slice(lines.indexOf('## Images') + 1);
  const end = rest.findIndex((line) => line.startsWith('## '));
  const stop = end === -1 ? rest.length : end;

  return lines.includes('## Images') ? rest.slice(0, stop) : [];
}

function collectDigestImages(record: ReleaseRecord) {
  const images = record.pins.flatMap((pin) =>
    pin.lines.flatMap((line) =>
      Object.values(line.parts).flatMap((part) => (part.kind === 'digest' ? [part.image] : [])),
    ),
  );

  return [...new Set(images)];
}
