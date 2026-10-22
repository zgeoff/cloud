// Exits 1 with a message when no base commit is found, so a hook never checks an empty set.
import { resolve } from 'node:path';
import { parseArgs } from 'node:util';

interface CollectBranchFilesOptions {
  readonly cwd: string;

  // The whole environment of the git runs; left out, they inherit this process's.
  readonly env?: Readonly<Record<string, string | undefined>>;

  // Deleted files are listed too, so a hook can gate on a deletion-only change.
  readonly includeDeleted?: boolean;

  // Only the files that match one of these are listed; left out, every file is.
  readonly globs?: readonly string[];
}

export async function readBranchFiles(
  options: Readonly<CollectBranchFilesOptions>,
): Promise<string[]> {
  const head = await runGit(options, ['rev-parse', '--abbrev-ref', 'origin/HEAD']);

  const defaultBranch = head.exitCode === 0 ? head.stdout.trim() : 'origin/main';

  const base = await runGit(options, ['merge-base', 'HEAD', defaultBranch]);

  if (base.exitCode !== 0) {
    throw new Error(
      `cannot find the base of this branch: no merge base between HEAD and ${defaultBranch} (is the remote fetched?)`,
    );
  }

  const diff = await runGit(options, [
    'diff',
    '--name-only',
    ...(options.includeDeleted === true ? [] : ['--diff-filter=d']),
    base.stdout.trim(),
    'HEAD',
  ]);

  if (diff.exitCode !== 0) {
    throw new Error(`git diff failed: ${diff.stderr.trim()}`);
  }

  const files = diff.stdout.split('\n').filter((line) => line !== '');

  if (options.globs === undefined) {
    return files;
  }

  const globs = options.globs.map((pattern) => new Bun.Glob(pattern));

  return files.filter((file) => globs.some((glob) => glob.match(file)));
}

async function runGit(options: Readonly<CollectBranchFilesOptions>, args: readonly string[]) {
  const subprocess = Bun.spawn(['git', ...args], {
    cwd: options.cwd,
    ...(options.env === undefined ? {} : { env: { ...options.env } }),
    stdin: 'ignore',
    stdout: 'pipe',
    stderr: 'pipe',
  });

  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(subprocess.stdout).text(),
    new Response(subprocess.stderr).text(),
    subprocess.exited,
  ]);

  return { exitCode, stdout, stderr };
}

async function runCLI(): Promise<void> {
  try {
    const args = parseArgs({
      options: {
        'include-deleted': { type: 'boolean', default: false },
        glob: { type: 'string', multiple: true },
      },
    });

    const files = await readBranchFiles({
      cwd: resolve('.'),
      includeDeleted: args.values['include-deleted'],
      ...(args.values.glob === undefined ? {} : { globs: args.values.glob }),
    });

    if (files.length > 0) {
      process.stdout.write(`${files.join('\n')}\n`);
    }
  } catch (error) {
    process.stderr.write(
      `read-branch-files: ${error instanceof Error ? error.message : String(error)}\n`,
    );

    process.exit(1);
  }
}

if (import.meta.main) {
  await runCLI();
}
