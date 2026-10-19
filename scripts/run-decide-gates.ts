// The one path filter for CI, the NixOS checks and the prod apply, run as `bun
// scripts/run-decide-gates.ts [--github] <base> <head> <gate>...`: it prints `<gate>=true` when a
// commit after <base> up to <head> changes a file the gate's paths in .github/gates.yml match.
import { appendFile } from 'node:fs/promises';
import { join } from 'node:path';
import { parseArgs } from 'node:util';
import { ExitError } from './exit-error.ts';
import { loadGateManifest } from './load-gate-manifest.ts';
import type { Gate, GateManifest } from './load-gate-manifest.ts';
import { needsGate } from './needs-gate.ts';
import type { ScriptIO } from './run-or-exit.ts';
import { runOrExit } from './run-or-exit.ts';
import { runProcess } from './run-process.ts';
import { withExitCode } from './with-exit-code.ts';

export interface RunDecideGatesOptions extends ScriptIO {
  readonly args: readonly string[];

  // the checkout whose history the revisions name
  readonly cwd: string;
  readonly manifestPath: string;
  readonly githubOutput: string | undefined;
  readonly githubStepSummary: string | undefined;
}

const usage = 'usage: run-decide-gates.ts [--github] <base> <head> <gate>...';

// A revision git cannot resolve fails with git's status, so a caller never skips a check on an
// error. --github also appends the lines to the step outputs, and each false gate's skipped line
// to stdout and the step summary, so every run reports a result.
export function runDecideGates(options: Readonly<RunDecideGatesOptions>): Promise<number> {
  return withExitCode(options.printErr, async () => {
    const args = parseDecideGatesArgs(options.args);
    const github = args.github ? requireGitHubFiles(options) : undefined;

    const gates = await loadGates(options.manifestPath, args.gates);
    const paths = await readChangedPaths(options, args.base, args.head);

    const decisions = gates.map((gate: Gate) => ({
      gate,
      needed: paths === 'all' || needsGate(gate, paths),
    }));

    const lines = decisions.map((each) => `${each.gate.name}=${String(each.needed)}\n`).join('');

    options.printOut(lines);

    if (github === undefined) {
      return 0;
    }

    await appendFile(github.output, lines);

    const skipped = decisions.flatMap((each) =>
      !each.needed && each.gate.skipped !== undefined ? [`${each.gate.skipped}\n`] : [],
    );

    options.printOut(skipped.join(''));

    await appendFile(github.summary, skipped.join(''));

    return 0;
  });
}

interface DecideGatesArgs {
  readonly github: boolean;
  readonly base: string;
  readonly head: string;
  readonly gates: readonly string[];
}

// util.parseArgs throws on an option it does not know, such as a misspelt --github
function parseDecideGatesArgs(args: readonly string[]): DecideGatesArgs {
  const parsed = tryParseArgs(args);
  const [base = '', head = '', ...gates] = parsed?.positionals ?? [];

  if (base === '' || head === '' || gates.length === 0 || gates.includes('')) {
    throw new ExitError(2, usage);
  }

  return { github: parsed?.values.github === true, base, head, gates };
}

function tryParseArgs(args: readonly string[]) {
  try {
    return parseArgs({
      args: [...args],
      options: { github: { type: 'boolean' } },
      allowPositionals: true,
      strict: true,
    });
  } catch {
    return null;
  }
}

function requireGitHubFiles(options: Readonly<RunDecideGatesOptions>) {
  if (options.githubOutput === undefined || options.githubOutput === '') {
    throw new ExitError(2, 'run-decide-gates: --github needs GITHUB_OUTPUT');
  }

  if (options.githubStepSummary === undefined || options.githubStepSummary === '') {
    throw new ExitError(2, 'run-decide-gates: --github needs GITHUB_STEP_SUMMARY');
  }

  return { output: options.githubOutput, summary: options.githubStepSummary };
}

async function loadGates(manifestPath: string, names: readonly string[]): Promise<Gate[]> {
  const manifest: GateManifest = await loadGateManifest(manifestPath).catch((error: unknown) => {
    throw new ExitError(
      1,
      `run-decide-gates: ${error instanceof Error ? error.message : String(error)}`,
    );
  });

  return names.map((name: string) => {
    const gate = manifest.get(name);

    if (gate === undefined) {
      throw new ExitError(2, `run-decide-gates: ${manifestPath} has no gate ${name}`);
    }

    return gate;
  });
}

// Each commit's paths, not the two trees', so a reverted change still counts; a rename counts both
// paths, and a merge its change against its first parent. A base of all zeros, as a push that
// creates a branch reports, or one off head's history gives nothing to compare, so 'all'.
async function readChangedPaths(
  io: Readonly<RunDecideGatesOptions>,
  base: string,
  head: string,
): Promise<string[] | 'all'> {
  if (/^0+$/u.test(base)) {
    return 'all';
  }

  // exit 1 means not an ancestor, which includes a base with no history in common with head; any
  // other failure is git's error on a revision it cannot read
  const ancestor = await io.run(['git', 'merge-base', '--is-ancestor', base, head], {
    cwd: io.cwd,
  });

  if (ancestor.exitCode === 1) {
    return 'all';
  }

  if (ancestor.exitCode !== 0) {
    io.printErr(ancestor.stderr.toString());
    throw new ExitError(ancestor.exitCode, '');
  }

  const log = await runOrExit(
    io,
    [
      'git',
      'log',
      '-z',
      '--format=',
      '--no-renames',
      '--name-only',
      '--diff-merges=first-parent',
      `${base}..${head}`,
    ],
    { cwd: io.cwd },
  );

  return log.stdout
    .toString()
    .split('\0')
    .filter((path: string) => path !== '');
}

if (import.meta.main) {
  process.exitCode = await runDecideGates({
    args: process.argv.slice(2),
    cwd: process.cwd(),
    manifestPath: join(import.meta.dir, '..', '.github', 'gates.yml'),
    githubOutput: process.env['GITHUB_OUTPUT'],
    githubStepSummary: process.env['GITHUB_STEP_SUMMARY'],
    run: runProcess,
    printOut: (text) => {
      process.stdout.write(text);
    },
    printErr: (text) => {
      process.stderr.write(text);
    },
  });
}
