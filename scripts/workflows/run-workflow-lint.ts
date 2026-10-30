import { readFile, rename, rm } from 'node:fs/promises';
import { join } from 'node:path';
import type { Runner } from '../run-process.ts';
import { runProcess } from '../run-process.ts';

export interface RunWorkflowLintOptions {
  // the repo whose workflows the lint reads, and whose repo-sync caller pins the tools tag
  readonly root: string;

  readonly toolsURL: string;

  // one checkout of zgeoff/tools per tag, kept between runs
  readonly cacheDirectory: string;

  readonly env: Readonly<Record<string, string | undefined>>;
  readonly run: Runner;
  readonly printOut: (text: string) => void;
  readonly printErr: (text: string) => void;
}

const callerPath = '.github/workflows/repo-sync.yml';
const lintPath = 'sync/pre-push/run-workflows-check.ts';

export async function runWorkflowLint(options: Readonly<RunWorkflowLintOptions>): Promise<number> {
  const caller = await readFile(join(options.root, callerPath), 'utf8');

  const ref = findToolsRef(caller);

  if (ref === undefined) {
    options.printErr(`run-workflow-lint: ${callerPath} calls no zgeoff/tools workflow at a tag\n`);

    return 2;
  }

  const checkout = join(options.cacheDirectory, ref);

  const isKept = await Bun.file(join(checkout, lintPath)).exists();

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

// Two runs may clone the same tag at once, so each clones into its own folder and the first rename
// wins.
async function createToolsCheckout(
  options: Readonly<RunWorkflowLintOptions>,
  ref: string,
  checkout: string,
): Promise<undefined | Error> {
  const partial = `${checkout}.partial-${process.pid}`;

  await rm(partial, { recursive: true, force: true });

  const steps = [
    [
      'git',
      'clone',
      '--quiet',
      '--depth=1',
      `--branch=${ref}`,
      '--filter=blob:none',
      '--sparse',
      options.toolsURL,
      partial,
    ],
    ['git', '-C', partial, 'sparse-checkout', 'set', 'sync/pre-push'],
  ];

  for (const argv of steps) {
    const result = await options.run(argv, { env: options.env, timeoutMs: 120_000 });

    if (result.exitCode !== 0) {
      await rm(partial, { recursive: true, force: true });

      return new Error(
        result.stderr.toString().trim() || `${argv.join(' ')} exited ${result.exitCode}`,
      );
    }
  }

  await rename(partial, checkout).catch(() => rm(partial, { recursive: true, force: true }));

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
    printOut: (text) => {
      process.stdout.write(text);
    },
    printErr: (text) => {
      process.stderr.write(text);
    },
  });
}
