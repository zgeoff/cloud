import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { parseArgs } from 'node:util';
import { findJSONField } from './find-json-field.ts';

export interface CheckCIProfilesOptions {
  readonly args: readonly string[];
  readonly readText: (path: string) => Promise<string>;
  readonly printOut: (text: string) => void;
  readonly printErr: (text: string) => void;
}

const usage = 'usage: check-ci-profiles.ts [repo root]\n';

// the checks job's own steps, which run in both profiles and have no twin in the parallel jobs
const ownSteps = new Set([
  'run: bun run ci:check-needs',
  'run: bun run --silent ci:write-ci-pass-name "$RECORD"',
  'uses: actions/checkout',
  'uses: oven-sh/setup-bun',
  'uses: actions/upload-artifact',
]);

// CI's two profiles run the same checks: the steps of the parallel jobs, which run while the
// repository is public, and the checks job's steps, which run every check once it is private.
export async function checkCIProfiles(options: Readonly<CheckCIProfilesOptions>): Promise<number> {
  const root = parseRoot(options.args);

  if (root === undefined) {
    options.printErr(usage);

    return 2;
  }

  const text = await options.readText(join(root, '.github', 'workflows', 'ci.yml'));

  const workflow: unknown = Bun.YAML.parse(text);
  const jobs = findJSONField(workflow, 'jobs');
  const parallel = collectParallelSteps(jobs);
  const single = collectSteps(findJSONField(jobs, 'checks')).filter((step) => !ownSteps.has(step));

  const violations = [
    ...[...new Set(parallel)]
      .filter((step) => !single.includes(step))
      .map((step) => `ci.yml: the checks job has no private-profile step for \`${step}\`\n`),
    ...[...new Set(single)]
      .filter((step) => !parallel.includes(step))
      .map((step) => `ci.yml: no parallel job runs the checks job's step \`${step}\`\n`),
    ...collectReusedSecretScans(jobs).map(
      (job) =>
        `ci.yml: the ${job} job skips its secret scan on a reused push, whose history no pull request run scanned\n`,
    ),
  ];

  if (violations.length > 0) {
    options.printErr(violations.join(''));

    return 1;
  }

  options.printOut("check-ci-profiles: the private checks job runs every parallel job's steps\n");

  return 0;
}

function parseRoot(args: readonly string[]): string | undefined {
  const positionals = tryParsePositionals(args);

  if (positionals === null || positionals.length > 1) {
    return undefined;
  }

  return positionals[0] ?? '.';
}

// util.parseArgs throws on an option it does not know, such as a misspelt flag
function tryParsePositionals(args: readonly string[]): string[] | null {
  try {
    return parseArgs({ args: [...args], options: {}, allowPositionals: true, strict: true })
      .positionals;
  } catch {
    return null;
  }
}

function collectParallelSteps(jobs: unknown): string[] {
  if (typeof jobs !== 'object' || jobs === null) {
    return [];
  }

  return Object.entries(jobs).flatMap((entry: readonly [string, unknown]) =>
    entry[0] === 'checks' ? [] : collectSteps(entry[1]).filter((step) => !ownSteps.has(step)),
  );
}

// a step's identity: its run command, or the action it uses without the pinned ref
function collectSteps(job: unknown): string[] {
  const steps = findJSONField(job, 'steps');

  if (!Array.isArray(steps)) {
    return [];
  }

  return steps.flatMap((step: unknown) => {
    const run = findJSONField(step, 'run');
    const uses = findJSONField(step, 'uses');

    if (typeof run === 'string') {
      return [`run: ${run.trim()}`];
    }

    return typeof uses === 'string' ? [`uses: ${uses.split('@')[0] ?? uses}`] : [];
  });
}

// a reuse matches trees, and a secret committed then removed leaves the same tree, so the scan of
// a push's history never waits on the reuse decision
function collectReusedSecretScans(jobs: unknown): string[] {
  if (typeof jobs !== 'object' || jobs === null) {
    return [];
  }

  return Object.entries(jobs).flatMap((entry: readonly [string, unknown]) => {
    const steps = findJSONField(entry[1], 'steps');
    const jobCondition = toCondition(findJSONField(entry[1], 'if'));

    if (!Array.isArray(steps)) {
      return [];
    }

    const reused = steps.some((step: unknown) => {
      const uses = findJSONField(step, 'uses');

      return (
        typeof uses === 'string' &&
        uses.startsWith('gitleaks/gitleaks-action@') &&
        `${jobCondition} ${toCondition(findJSONField(step, 'if'))}`.includes('reused')
      );
    });

    return reused ? [entry[0]] : [];
  });
}

function toCondition(value: unknown): string {
  return typeof value === 'string' ? value : '';
}

if (import.meta.main) {
  process.exitCode = await checkCIProfiles({
    args: process.argv.slice(2),
    readText: (path) => readFile(path, 'utf8'),
    printOut: (text) => {
      process.stdout.write(text);
    },
    printErr: (text) => {
      process.stderr.write(text);
    },
  });
}
