// Runs in the nixie-backup image beside restore.sh, which holds bun and none of this repo's
// packages, so this file imports nothing.

const setTag = /^set-(?<sequence>[0-9]+)$/u;

// the newest set-<sequence> tag among the snapshots that `restic snapshots --json` prints, by
// number: set-10 sorts after set-9 only as a number
export function pickNewestSet(text: string): string | undefined | Error {
  const snapshots = parseSnapshots(text);

  if (snapshots instanceof Error) {
    return snapshots;
  }

  const sequences = snapshots.flatMap((snapshot) =>
    (snapshot.tags ?? []).flatMap((tag) => {
      const sequence = setTag.exec(tag)?.groups?.['sequence'];

      return sequence === undefined ? [] : [Number(sequence)];
    }),
  );

  return sequences.length === 0 ? undefined : `set-${Math.max(...sequences)}`;
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
