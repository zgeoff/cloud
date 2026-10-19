import { readFile } from 'node:fs/promises';
import { collectPlanHolds } from './collect-plan-holds.ts';
import { findJSONField } from './find-json-field.ts';

export interface CheckProdPlanOptions {
  readonly args: readonly string[];
  readonly printOut: (text: string) => void;
  readonly printErr: (text: string) => void;
}

const usage = 'usage: check-prod-plan.ts <preview digest> <drift outcome: success|failure>\n';

export async function checkProdPlan(options: Readonly<CheckProdPlanOptions>): Promise<number> {
  const args = parseArgs(options.args);

  if (args === undefined) {
    options.printErr(usage);

    return 2;
  }

  const digest = await loadDigest(args.digestPath);

  if (digest === undefined) {
    options.printErr(`check-prod-plan: ${args.digestPath} holds no preview digest\n`);

    return 1;
  }

  return printVerdict(digest, args.driftPassed, options);
}

interface CheckProdPlanArgs {
  readonly digestPath: string;
  readonly driftPassed: boolean;
}

function parseArgs(args: readonly string[]): CheckProdPlanArgs | undefined {
  const [digestPath, driftOutcome] = args;

  if (args.length !== 2 || digestPath === undefined) {
    return undefined;
  }

  if (driftOutcome !== 'success' && driftOutcome !== 'failure') {
    return undefined;
  }

  return { digestPath, driftPassed: driftOutcome === 'success' };
}

async function loadDigest(path: string): Promise<unknown> {
  const text = await readFile(path, 'utf8').catch(() => null);

  if (text === null) {
    return undefined;
  }

  try {
    const digest: unknown = JSON.parse(text);

    return digest;
  } catch {
    return undefined;
  }
}

function printVerdict(
  digest: unknown,
  driftPassed: boolean,
  options: Readonly<CheckProdPlanOptions>,
): number {
  const errors = collectErrorMessages(digest);

  if (errors.length > 0) {
    options.printErr(errors.map((message) => `preview error: ${message}\n`).join(''));

    return 1;
  }

  const holds = [
    ...(driftPassed ? [] : ['the drift check from the deployed revision failed']),
    ...collectPlanHolds(digest),
  ];

  if (holds.length === 0) {
    options.printOut('apply: the plan holds no delete, replace or guarded change\n');

    return 0;
  }

  // never print a resource's state here: the job's log is public
  options.printOut(`hold: ${holds.map((hold) => `\n- ${hold}`).join('')}\n`);

  return 3;
}

function collectErrorMessages(digest: unknown): string[] {
  const diagnostics = findJSONField(digest, 'diagnostics');

  if (!Array.isArray(diagnostics)) {
    return [];
  }

  return diagnostics
    .filter((diagnostic: unknown) => findJSONField(diagnostic, 'severity') === 'error')
    .map((diagnostic: unknown) => String(findJSONField(diagnostic, 'message')).trim());
}

if (import.meta.main) {
  process.exitCode = await checkProdPlan({
    args: process.argv.slice(2),
    printOut: (text) => {
      process.stdout.write(text);
    },
    printErr: (text) => {
      process.stderr.write(text);
    },
  });
}
