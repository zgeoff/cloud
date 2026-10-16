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

// queued: claimed and not yet started; waiting: the preview slots were full, and the commit status
// says so; running: the suite runs in its imp; settling: the result waits for the imp's removal and
// its commit status; passed and failed: the commit status holds the result
type ContractPhase = 'queued' | 'waiting' | 'running' | 'settling' | 'passed' | 'failed';

// the state of the commit status that a run's result sets
export type ContractOutcome = 'success' | 'failure' | 'error';

export interface ContractRunKey {
  // owner/name of the repository the pull request targets
  readonly repo: string;
  readonly headSHA: string;
}

export interface ContractRun extends ContractRunKey {
  readonly number: number;
  readonly imp: string;
  readonly phase: ContractPhase;
  readonly detail: string | null;

  // the result's status, from settling on
  readonly outcome: ContractOutcome | null;
}

interface ContractPhaseChange {
  readonly phase: ContractPhase;
  readonly detail?: string;
  readonly outcome?: ContractOutcome;
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

  // records a queued run of the SDK contract suite for a head commit, and reports whether this
  // call recorded it, so a commit runs the suite once however many deliveries name it
  readonly claimContractRun: (run: Omit<ContractRun, 'phase' | 'detail' | 'outcome'>) => boolean;
  readonly findContractRun: (key: ContractRunKey) => ContractRun | null;

  // the runs at one of `phases`, oldest claim first
  readonly collectContractRuns: (phases: readonly ContractPhase[]) => ContractRun[];

  // moves the run to `to` only while it stands at one of `from`, and reports whether it moved
  readonly updateContractPhase: (
    key: ContractRunKey,
    from: readonly ContractPhase[],
    to: ContractPhaseChange,
  ) => boolean;

  // queues again every run a stopped process left in `running`, so the next retry starts it over;
  // returns how many it queued
  readonly updateInterruptedContractRuns: () => number;
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

// A reopened preview, and a failed one whose head moved, wait for the next open again. SET reads
// the row as it was before the update, so each CASE compares the old head.
const restartsWhen = `phase = 'ended' OR (phase = 'failed' AND head_sha <> excluded.head_sha)`;

const upsertHeadSQL = `INSERT INTO previews (repo, number, imp, head_sha, phase)
  VALUES (?1, ?2, ?3, ?4, 'waiting')
  ON CONFLICT (repo, number) DO UPDATE SET head_sha = excluded.head_sha,
    phase = CASE WHEN ${restartsWhen} THEN 'waiting' ELSE phase END,
    detail = CASE WHEN ${restartsWhen} THEN NULL ELSE detail END`;

// The service's own record of each pull request it has seen, in one SQLite file. impd stays the
// source of truth for whether an imp runs or sleeps.
export function createPreviewStore(path: string): PreviewStore {
  const db = new Database(path, { create: true, strict: true });

  createPreviewsTable(db);
  createContractRunsTable(db);

  const select = db.query<PreviewRow, [string, number]>(
    'SELECT * FROM previews WHERE repo = ?1 AND number = ?2',
  );

  const upsert = db.query(upsertHeadSQL);

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
    ...buildContractRunMethods(db),
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

function createContractRunsTable(db: Database): void {
  db.run(`CREATE TABLE IF NOT EXISTS contract_runs (
    repo TEXT NOT NULL,
    head_sha TEXT NOT NULL,
    number INTEGER NOT NULL,
    imp TEXT NOT NULL,
    phase TEXT NOT NULL,
    detail TEXT,
    outcome TEXT,
    PRIMARY KEY (repo, head_sha)
  ) STRICT`);
}

interface ContractRunRow {
  readonly repo: string;
  readonly head_sha: string;
  readonly number: number;
  readonly imp: string;
  readonly phase: ContractPhase;
  readonly detail: string | null;
  readonly outcome: ContractOutcome | null;
}

type ContractRunMethods = Pick<
  PreviewStore,
  | 'claimContractRun'
  | 'findContractRun'
  | 'collectContractRuns'
  | 'updateContractPhase'
  | 'updateInterruptedContractRuns'
>;

function buildContractRunMethods(db: Database): ContractRunMethods {
  const claim = db.query(`INSERT INTO contract_runs (repo, head_sha, number, imp, phase)
    VALUES (?1, ?2, ?3, ?4, 'queued') ON CONFLICT (repo, head_sha) DO NOTHING`);

  const select = db.query<ContractRunRow, [string, string]>(
    'SELECT * FROM contract_runs WHERE repo = ?1 AND head_sha = ?2',
  );

  const selectByPhase = db.query<ContractRunRow, [string]>(
    'SELECT * FROM contract_runs WHERE phase IN (SELECT value FROM json_each(?1)) ORDER BY rowid',
  );

  const update = db.query(`UPDATE contract_runs SET phase = ?3, detail = ?4, outcome = ?5
    WHERE repo = ?1 AND head_sha = ?2 AND phase IN (SELECT value FROM json_each(?6))`);

  return {
    claimContractRun: (run) => claim.run(run.repo, run.headSHA, run.number, run.imp).changes === 1,
    findContractRun: (key) => {
      const row = select.get(key.repo, key.headSHA);

      return row === null ? null : toContractRun(row);
    },
    collectContractRuns: (phases) =>
      selectByPhase.all(JSON.stringify(phases)).map((row) => toContractRun(row)),
    updateContractPhase: (key, from, to) => {
      const detail = to.detail ?? null;
      const outcome = to.outcome ?? null;

      return (
        update.run(key.repo, key.headSHA, to.phase, detail, outcome, JSON.stringify(from))
          .changes === 1
      );
    },
    updateInterruptedContractRuns: () =>
      db.run(`UPDATE contract_runs SET phase = 'queued', detail = NULL WHERE phase = 'running'`)
        .changes,
  };
}

function toContractRun(row: ContractRunRow): ContractRun {
  return {
    repo: row.repo,
    headSHA: row.head_sha,
    number: row.number,
    imp: row.imp,
    phase: row.phase,
    detail: row.detail,
    outcome: row.outcome,
  };
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
