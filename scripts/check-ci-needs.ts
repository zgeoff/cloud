import { findJSONField } from './find-json-field.ts';

// CI's checks job, which the ruleset requires, passes only when each job it needs passed or its
// path gate skipped it. A job that its timeout ended reports cancelled, so cancelled fails too.
export interface CheckCINeedsOptions {
  readonly needs: string | undefined;
  readonly printOut: (text: string) => void;
  readonly printErr: (text: string) => void;
}

const passed = new Set(['success', 'skipped']);

export function checkCINeeds(options: Readonly<CheckCINeedsOptions>): number {
  const results = parseResults(options.needs);

  if (results === undefined) {
    options.printErr('check-ci-needs: NEEDS must hold the toJSON(needs) of at least one job\n');

    return 2;
  }

  const failed = results.filter((entry) => !passed.has(entry.result));

  if (failed.length > 0) {
    options.printErr(
      failed.map((entry) => `check-ci-needs: ${entry.job} ended ${entry.result}\n`).join(''),
    );

    return 1;
  }

  options.printOut(`check-ci-needs: ${results.length} jobs passed or were skipped\n`);

  return 0;
}

interface JobResult {
  readonly job: string;
  readonly result: string;
}

function parseResults(needs: string | undefined): JobResult[] | undefined {
  const parsed = tryParseJSON(needs ?? '');

  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    return undefined;
  }

  const results = Object.keys(parsed).map((job) => {
    const result = findJSONField(findJSONField(parsed, job), 'result');

    return { job, result: typeof result === 'string' ? result : 'without a result' };
  });

  return results.length > 0 ? results : undefined;
}

function tryParseJSON(text: string): unknown {
  try {
    const value: unknown = JSON.parse(text);

    return value;
  } catch {
    return undefined;
  }
}

if (import.meta.main) {
  process.exitCode = checkCINeeds({
    needs: process.env['NEEDS'],
    printOut: (text) => {
      process.stdout.write(text);
    },
    printErr: (text) => {
      process.stderr.write(text);
    },
  });
}
