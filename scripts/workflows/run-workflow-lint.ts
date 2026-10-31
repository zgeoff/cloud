import { readFile, rename, rm } from 'node:fs/promises';
import { join } from 'node:path';
import type { Runner } from '../run-process.ts';
import { runProcess } from '../run-process.ts';

export interface RunWorkflowLintOptions {
  readonly root: string;

  readonly toolsURL: string;

  readonly cacheDirectory: string;

  readonly env: Readonly<Record<string, string | undefined>>;
  readonly run: Runner;
  readonly readText: (path: string) => Promise<string>;
  readonly probeFile: (path: string) => Promise<boolean>;
  readonly removeTree: (path: string) => Promise<void>;
  readonly renameTree: (from: string, to: string) => Promise<void>;
  readonly printOut: (text: string) => void;
  readonly printErr: (text: string) => void;
}

const callerPath = '.github/workflows/repo-sync.yml';
const lintPath = 'sync/pre-push/run-workflows-check.ts';

export async function runWorkflowLint(options: Readonly<RunWorkflowLintOptions>): Promise<number> {
  const caller = await options.readText(join(options.root, callerPath));

  const ref = findToolsRef(caller);

  if (ref === undefined) {
    options.printErr(`run-workflow-lint: ${callerPath} calls no zgeoff/tools workflow at a ref\n`);

    return 2;
  }

  const checkout = join(options.cacheDirectory, ref);

  const isKept = await options.probeFile(join(checkout, lintPath));

  const cloned = isKept ? undefined : await createToolsCheckout(options, ref, checkout);

  if (cloned instanceof Error) {
    options.printErr(
      `run-workflow-lint: cannot check out zgeoff/tools ${ref}: ${cloned.message}\n`,
    );

    return 1;
  }

  const result = await options.run([process.execPath, join(checkout, lintPath)], {
    cwd: options.root,
    env: options.env,
  });

  options.printOut(result.stdout.toString());
  options.printErr(result.stderr.toString());

  return result.exitCode;
}

const toolsWorkflowPattern = /^zgeoff\/tools\/\.github\/workflows\/[^@]+@(?<ref>[\w.-]+)$/u;

function findToolsRef(text: string): string | undefined {
  const workflow: unknown = Bun.YAML.parse(text);
  const jobs = findMember(workflow, 'jobs');

  const definitions: readonly unknown[] =
    typeof jobs === 'object' && jobs !== null ? Object.values(jobs) : [];

  return definitions
    .map((job) => findMember(job, 'uses'))
    .map((uses) =>
      typeof uses === 'string' ? toolsWorkflowPattern.exec(uses)?.groups?.['ref'] : undefined,
    )
    .find((ref) => ref !== undefined);
}

function findMember(value: unknown, key: string): unknown {
  return typeof value === 'object' && value !== null && Object.hasOwn(value, key)
    ? Reflect.get(value, key)
    : undefined;
}

// Two runs may check out the same ref at once, so each checks out into its own folder and the first rename
// wins.
async function createToolsCheckout(
  options: Readonly<RunWorkflowLintOptions>,
  ref: string,
  checkout: string,
): Promise<undefined | Error> {
  const partial = `${checkout}.partial-${process.pid}`;

  await options.removeTree(partial);

  const steps = [
    ['git', 'init', '--quiet', partial],
    ['git', '-C', partial, 'sparse-checkout', 'set', 'sync/pre-push'],
    [
      'git',
      '-C',
      partial,
      'fetch',
      '--quiet',
      '--depth=1',
      '--filter=blob:none',
      options.toolsURL,
      ref,
    ],
    ['git', '-C', partial, 'checkout', '--quiet', 'FETCH_HEAD'],
  ];

  for (const argv of steps) {
    const result = await options.run(argv, { env: options.env, timeoutMs: 120_000 });

    if (result.exitCode !== 0) {
      await options.removeTree(partial);

      return new Error(
        result.stderr.toString().trim() || `${argv.join(' ')} exited ${result.exitCode}`,
      );
    }
  }

  await options.renameTree(partial, checkout).catch(() => options.removeTree(partial));

  return undefined;
}

if (import.meta.main) {
  const root = process.cwd();

  process.exitCode = await runWorkflowLint({
    root,
    toolsURL: 'https://github.com/zgeoff/tools',
    cacheDirectory: join(root, 'node_modules', '.cache', 'zgeoff-tools'),
    env: process.env,
    run: runProcess,
    readText: (path) => readFile(path, 'utf8'),
    probeFile: (path) => Bun.file(path).exists(),
    removeTree: (path) => rm(path, { recursive: true, force: true }),
    renameTree: (from, to) => rename(from, to),
    printOut: (text) => {
      process.stdout.write(text);
    },
    printErr: (text) => {
      process.stderr.write(text);
    },
  });
}
