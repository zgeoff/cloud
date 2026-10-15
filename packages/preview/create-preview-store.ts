import { Database } from 'bun:sqlite';

// waiting: the next open boots the head commit; booting: a boot runs; ready: builtSHA answered its
// health path; failed: the last boot failed, and `detail` says why; ended: the pull request closed
type PreviewPhase = 'waiting' | 'booting' | 'ready' | 'failed' | 'ended';

export interface PreviewKey {
  // owner/name of the repository the pull request targets
  readonly repo: string;
  readonly number: number;
}

export interface Preview extends PreviewKey {
  readonly imp: string;
  readonly headSHA: string;

  // the commit the imp last booted, which differs from headSHA after a push
  readonly builtSHA: string | null;
  readonly phase: PreviewPhase;
  readonly detail: string | null;
}

export interface PhaseChange {
  readonly phase: PreviewPhase;
  readonly builtSHA?: string;
  readonly detail?: string;
}

interface PreviewHead extends PreviewKey {
  readonly imp: string;
  readonly headSHA: string;
}

export interface PreviewStore {
  readonly findPreview: (key: PreviewKey) => Preview | null;

  // records the pull request's head; a closed pull request that reopens waits again
  readonly upsertHead: (head: PreviewHead) => void;

  // moves the preview to `to` only while it stands at one of `from`, and reports whether it moved,
  // so a boot that ends after its pull request closed never revives it
  readonly updatePhase: (
    key: PreviewKey,
    from: readonly PreviewPhase[],
    to: PhaseChange,
  ) => boolean;

  // fails every boot a stopped process left in `booting`, so its next open retries it; returns
  // how many it failed
  readonly updateInterruptedBoots: () => number;
  readonly close: () => void;
}

interface PreviewRow {
  readonly repo: string;
  readonly number: number;
  readonly imp: string;
  readonly head_sha: string;
  readonly built_sha: string | null;
  readonly phase: PreviewPhase;
  readonly detail: string | null;
}

// The service's own record of each pull request it has seen, in one SQLite file. impd stays the
// source of truth for whether an imp runs or sleeps.
export function createPreviewStore(path: string): PreviewStore {
  const db = new Database(path, { create: true, strict: true });

  createPreviewsTable(db);

  const select = db.query<PreviewRow, [string, number]>(
    'SELECT * FROM previews WHERE repo = ?1 AND number = ?2',
  );

  const upsert = db.query(`INSERT INTO previews (repo, number, imp, head_sha, phase)
    VALUES (?1, ?2, ?3, ?4, 'waiting')
    ON CONFLICT (repo, number) DO UPDATE SET head_sha = excluded.head_sha,
      phase = CASE phase WHEN 'ended' THEN 'waiting' ELSE phase END`);

  const update = db.query(`UPDATE previews
    SET phase = ?3, built_sha = coalesce(?4, built_sha), detail = ?5
    WHERE repo = ?1 AND number = ?2 AND phase IN (SELECT value FROM json_each(?6))`);

  return {
    findPreview: (key) => {
      const row = select.get(key.repo, key.number);

      return row === null ? null : toPreview(row);
    },
    upsertHead: (head) => {
      upsert.run(head.repo, head.number, head.imp, head.headSHA);
    },
    updatePhase: (key, from, to) => {
      const builtSHA = to.builtSHA ?? null;
      const detail = to.detail ?? null;

      const result = update.run(
        key.repo,
        key.number,
        to.phase,
        builtSHA,
        detail,
        JSON.stringify(from),
      );

      return result.changes === 1;
    },
    updateInterruptedBoots: () => updateInterruptedBoots(db),
    close: () => {
      db.close();
    },
  };
}

function updateInterruptedBoots(db: Database): number {
  const detail = 'the service stopped during the boot';

  return db.run(`UPDATE previews SET phase = 'failed', detail = ?1 WHERE phase = 'booting'`, [
    detail,
  ]).changes;
}

function createPreviewsTable(db: Database): void {
  db.run('PRAGMA journal_mode = WAL');

  db.run(`CREATE TABLE IF NOT EXISTS previews (
    repo TEXT NOT NULL,
    number INTEGER NOT NULL,
    imp TEXT NOT NULL,
    head_sha TEXT NOT NULL,
    built_sha TEXT,
    phase TEXT NOT NULL,
    detail TEXT,
    PRIMARY KEY (repo, number)
  ) STRICT`);
}

function toPreview(row: PreviewRow): Preview {
  return {
    repo: row.repo,
    number: row.number,
    imp: row.imp,
    headSHA: row.head_sha,
    builtSHA: row.built_sha,
    phase: row.phase,
    detail: row.detail,
  };
}
