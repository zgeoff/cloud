// Runs in the nixie-backup image beside restore.sh, which holds bun and none of this repo's
// packages, so this file imports nothing.

const setTag = /^set-(?<number>[0-9]+)$/u;
const publishTag = /^publish-(?<number>[0-9]+)$/u;
const legacySetTag = /^legacy-set-(?<number>[0-9]+)$/u;

// the newest snapshot's tags as a --tag filter, by publish number once every snapshot has one,
// because a set number repeats after a restore; else by set number (nixie's backup-pair design)
export function pickNewestSet(text: string): string | undefined | Error {
  const snapshots = parseSnapshots(text);

  if (snapshots instanceof Error) {
    return snapshots;
  }

  const published = snapshots.flatMap((snapshot) => {
    const tags = snapshot.tags ?? [];
    const set = parseTagNumber(tags, setTag);

    return set === undefined
      ? []
      : [
          {
            set,
            publish: parseTagNumber(tags, publishTag),
            legacySet: parseTagNumber(tags, legacySetTag),
          },
        ];
  });

  const replaced = new Set(published.map((snapshot) => snapshot.legacySet));

  const remaining = published.filter(
    (snapshot) => snapshot.publish !== undefined || !replaced.has(snapshot.set),
  );

  if (remaining.length === 0) {
    return undefined;
  }

  const isNumbered = remaining.every((snapshot) => snapshot.publish !== undefined);

  const newest = remaining.reduce((best, snapshot) =>
    (isNumbered ? (snapshot.publish ?? 0) > (best.publish ?? 0) : snapshot.set > best.set)
      ? snapshot
      : best,
  );

  return newest.publish === undefined
    ? `set-${newest.set}`
    : `set-${newest.set},publish-${newest.publish}`;
}

interface Snapshot {
  readonly id: string;
  readonly tags?: readonly string[];
}

function parseSnapshots(text: string): readonly Snapshot[] | Error {
  const parsed = parseJSON(text);

  return Array.isArray(parsed) && parsed.every((value) => isSnapshot(value))
    ? parsed
    : new Error('restic printed no snapshot list');
}

function parseJSON(text: string): unknown {
  try {
    const parsed: unknown = JSON.parse(text);

    return parsed;
  } catch {
    return undefined;
  }
}

function isSnapshot(value: unknown): value is Snapshot {
  if (typeof value !== 'object' || value === null || !('id' in value)) {
    return false;
  }

  const tags = 'tags' in value ? value.tags : undefined;

  return (
    typeof value.id === 'string' &&
    (tags === undefined || (Array.isArray(tags) && tags.every((tag) => typeof tag === 'string')))
  );
}

function parseTagNumber(tags: readonly string[], pattern: RegExp): number | undefined {
  const found = tags
    .map((tag) => pattern.exec(tag)?.groups?.['number'])
    .find((value) => value !== undefined);

  return found === undefined ? undefined : Number(found);
}

// restore.sh pipes the list in, and reads the tag from stdout or the reason from stderr
if (import.meta.main) {
  const text = await Bun.stdin.text();

  const picked = pickNewestSet(text);

  if (picked instanceof Error) {
    process.stderr.write(`${picked.message}\n`);

    process.exitCode = 1;
  } else if (picked !== undefined) {
    process.stdout.write(`${picked}\n`);
  }
}
