import { Database } from 'bun:sqlite';
import { z } from 'zod';

const previewPhaseSchema = z.enum(['waiting', 'booting', 'ready', 'failed', 'ended']);

type PreviewPhase = z.infer<typeof previewPhaseSchema>;

export interface PreviewKey {
  readonly repo: string;
  readonly number: number;
}

export interface Preview extends PreviewKey {
  readonly imp: string;
  readonly headSHA: string;

  readonly builtSHA: string | null;
  readonly phase: PreviewPhase;
  readonly detail: string | null;
}

export interface PhaseChange {
  readonly phase: PreviewPhase;
  readonly builtSHA?: string;
  readonly detail?: string;
}

const contractPhaseSchema = z.enum([
  'queued',
  'waiting',
  'running',
  'settling',
  'passed',
  'failed',
]);

type ContractPhase = z.infer<typeof contractPhaseSchema>;

const contractOutcomeSchema = z.enum(['success', 'failure', 'error']);

export type ContractOutcome = z.infer<typeof contractOutcomeSchema>;

export interface ContractRunKey {
  readonly repo: string;
  readonly headSHA: string;
}

export interface ContractRun extends ContractRunKey {
  readonly number: number;
  readonly imp: string;
  readonly phase: ContractPhase;
  readonly detail: string | null;

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

  readonly upsertHead: (head: PreviewHead) => void;

  // Moves only from a phase in `from`, so a boot that ends after its pull request closed never
  // revives it
  readonly updatePhase: (
    key: PreviewKey,
    from: readonly PreviewPhase[],
    to: PhaseChange,
  ) => boolean;

  readonly updateInterruptedBoots: () => number;

  // Reports whether this call recorded the run, so a commit runs the suite once however many
  // deliveries name it
  readonly claimContractRun: (run: Omit<ContractRun, 'phase' | 'detail' | 'outcome'>) => boolean;
  readonly findContractRun: (key: ContractRunKey) => ContractRun | null;

  readonly collectContractRuns: (phases: readonly ContractPhase[]) => ContractRun[];

  readonly updateContractPhase: (
    key: ContractRunKey,
    from: readonly ContractPhase[],
    to: ContractPhaseChange,
  ) => boolean;

  readonly updateInterruptedContractRuns: () => number;
  readonly close: () => void;
}

export function createPreviewStore(path: string): PreviewStore {
  const db = new Database(path, { create: true, strict: true });

  createPreviewsTable(db);
  createContractRunsTable(db);

  return {
    ...bindPreviewMethods(db),
    ...bindContractRunMethods(db),
    close: () => {
      db.close();
    },
  };
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

type PreviewMethods = Pick<
  PreviewStore,
  'findPreview' | 'upsertHead' | 'updatePhase' | 'updateInterruptedBoots'
>;

const firstPhase: PreviewPhase = 'waiting';

const previewRowSchema = z.object({
  repo: z.string(),
  number: z.number(),
  imp: z.string(),
  head_sha: z.string(),
  built_sha: z.string().nullable(),
  phase: previewPhaseSchema,
  detail: z.string().nullable(),
});

type PreviewRow = z.infer<typeof previewRowSchema>;

function bindPreviewMethods(db: Database): PreviewMethods {
  const select = db.query('SELECT * FROM previews WHERE repo = ?1 AND number = ?2');
  const selectBooting = db.query(`SELECT * FROM previews WHERE phase = 'booting'`);

  const findRow = (key: PreviewKey): PreviewRow | null =>
    previewRowSchema.nullable().parse(select.get(key.repo, key.number));

  const upsert = db.query(`INSERT INTO previews (repo, number, imp, head_sha, phase)
    VALUES (?1, ?2, ?3, ?4, ?5)
    ON CONFLICT (repo, number) DO UPDATE SET head_sha = excluded.head_sha`);

  const update = db.query(`UPDATE previews
    SET phase = ?3, built_sha = coalesce(?4, built_sha), detail = ?5
    WHERE repo = ?1 AND number = ?2 AND phase IN (SELECT value FROM json_each(?6))`);

  const updatePhase: PreviewStore['updatePhase'] = (key, from, to) => {
    assertPhaseMoves(from, to.phase);

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
  };

  const upsertHead = db.transaction((head: PreviewHead) => {
    const before = findRow(head);

    upsert.run(head.repo, head.number, head.imp, head.headSHA, firstPhase);

    if (before !== null && shouldRestart(before, head.headSHA)) {
      updatePhase(head, [before.phase], { phase: 'waiting' });
    }
  });

  const updateInterruptedBoots = db.transaction(() => {
    const detail = 'the service stopped during the boot';

    return z
      .array(previewRowSchema)
      .parse(selectBooting.all())
      .filter((row) => updatePhase(toPreview(row), ['booting'], { phase: 'failed', detail }))
      .length;
  });

  return {
    findPreview: (key) => {
      const row = findRow(key);

      return row === null ? null : toPreview(row);
    },
    upsertHead: (head) => {
      upsertHead(head);
    },
    updatePhase,
    updateInterruptedBoots: () => updateInterruptedBoots(),
  };
}

const phaseMoves: Readonly<Record<PreviewPhase, readonly PreviewPhase[]>> = {
  waiting: ['booting', 'ended'],

  booting: ['ready', 'failed', 'waiting', 'ended'],

  ready: ['booting', 'ended'],

  failed: ['booting', 'waiting', 'ended'],

  ended: ['waiting'],
};

function assertPhaseMoves(from: readonly PreviewPhase[], to: PreviewPhase): void {
  const refused = from.find((phase) => !phaseMoves[phase].includes(to));

  if (refused !== undefined) {
    throw new Error(`a preview cannot move from ${refused} to ${to}`);
  }
}

function shouldRestart(row: PreviewRow, headSHA: string): boolean {
  return row.phase === 'ended' || (row.phase === 'failed' && row.head_sha !== headSHA);
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

const contractRunRowSchema = z.object({
  repo: z.string(),
  head_sha: z.string(),
  number: z.number(),
  imp: z.string(),
  phase: contractPhaseSchema,
  detail: z.string().nullable(),
  outcome: contractOutcomeSchema.nullable(),
});

type ContractRunRow = z.infer<typeof contractRunRowSchema>;

type ContractRunMethods = Pick<
  PreviewStore,
  | 'claimContractRun'
  | 'findContractRun'
  | 'collectContractRuns'
  | 'updateContractPhase'
  | 'updateInterruptedContractRuns'
>;

function bindContractRunMethods(db: Database): ContractRunMethods {
  const claim = db.query(`INSERT INTO contract_runs (repo, head_sha, number, imp, phase)
    VALUES (?1, ?2, ?3, ?4, 'queued') ON CONFLICT (repo, head_sha) DO NOTHING`);

  const select = db.query('SELECT * FROM contract_runs WHERE repo = ?1 AND head_sha = ?2');

  const selectByPhase = db.query(
    'SELECT * FROM contract_runs WHERE phase IN (SELECT value FROM json_each(?1)) ORDER BY rowid',
  );

  const collectRows = (phases: readonly ContractPhase[]): ContractRunRow[] =>
    z.array(contractRunRowSchema).parse(selectByPhase.all(JSON.stringify(phases)));

  const update = db.query(`UPDATE contract_runs SET phase = ?3, detail = ?4, outcome = ?5
    WHERE repo = ?1 AND head_sha = ?2 AND phase IN (SELECT value FROM json_each(?6))`);

  const updateContractPhase: PreviewStore['updateContractPhase'] = (key, from, to) => {
    assertContractPhaseMoves(from, to.phase);

    const detail = to.detail ?? null;
    const outcome = to.outcome ?? null;

    const result = update.run(
      key.repo,
      key.headSHA,
      to.phase,
      detail,
      outcome,
      JSON.stringify(from),
    );

    return result.changes === 1;
  };

  const updateInterruptedContractRuns = db.transaction(
    () =>
      collectRows(['running']).filter((row) =>
        updateContractPhase(toContractRun(row), ['running'], { phase: 'queued' }),
      ).length,
  );

  return {
    claimContractRun: (run) => claim.run(run.repo, run.headSHA, run.number, run.imp).changes === 1,
    findContractRun: (key) => {
      const row = contractRunRowSchema.nullable().parse(select.get(key.repo, key.headSHA));

      return row === null ? null : toContractRun(row);
    },
    collectContractRuns: (phases) => collectRows(phases).map((row) => toContractRun(row)),
    updateContractPhase,
    updateInterruptedContractRuns: () => updateInterruptedContractRuns(),
  };
}

const contractPhaseMoves: Readonly<Record<ContractPhase, readonly ContractPhase[]>> = {
  queued: ['waiting', 'running', 'settling'],

  waiting: ['running', 'settling'],

  running: ['settling', 'queued'],

  settling: ['passed', 'failed'],

  passed: [],
  failed: [],
};

function assertContractPhaseMoves(from: readonly ContractPhase[], to: ContractPhase): void {
  const refused = from.find((phase) => !contractPhaseMoves[phase].includes(to));

  if (refused !== undefined) {
    throw new Error(`a contract run cannot move from ${refused} to ${to}`);
  }
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
