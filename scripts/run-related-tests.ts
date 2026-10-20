import { existsSync } from 'node:fs';
import { dirname, join, relative } from 'node:path';

export function resolveRelatedTests(paths: readonly string[], cwd: string): string[] {
  const selected = new Set<string>();

  for (const path of paths) {
    if (path.endsWith('.test.ts')) {
      if (existsSync(join(cwd, path))) {
        selected.add(path);
      }
    } else if (path.endsWith('.ts') && !path.endsWith('.d.ts')) {
      const sibling = `${path.slice(0, -'.ts'.length)}.test.ts`;

      if (existsSync(join(cwd, sibling))) {
        selected.add(sibling);
      }
    }
  }

  return [...selected];
}

export async function runRelatedTests(paths: readonly string[], cwd: string): Promise<number> {
  const tests = resolveRelatedTests(paths, cwd);

  if (tests.length === 0) {
    process.stdout.write('run-related-tests: no related tests\n');

    return 0;
  }

  for (const [packageDir, packageTests] of Map.groupBy(tests, (test) =>
    resolvePackageDir(test, cwd),
  )) {
    // one run at a time: the runs share the tree and its ports
    const exitCode = await runTests(cwd, packageDir, packageTests);

    if (exitCode !== 0) {
      return exitCode;
    }
  }

  return 0;
}

function resolvePackageDir(test: string, cwd: string): string | undefined {
  for (
    let directory = dirname(test);
    directory !== '.' && directory !== '/';
    directory = dirname(directory)
  ) {
    if (existsSync(join(cwd, directory, 'bunfig.toml'))) {
      return directory;
    }
  }

  return undefined;
}

function runTests(
  cwd: string,
  packageDir: string | undefined,
  tests: readonly string[],
): Promise<number> {
  const command =
    packageDir === undefined
      ? ['bun', 'run', 'test', ...tests]
      : ['bun', 'test', ...tests.map((test) => relative(packageDir, test))];

  const run = Bun.spawn(command, {
    cwd: join(cwd, packageDir ?? ''),
    stdin: 'inherit',
    stdout: 'inherit',
    stderr: 'inherit',
  });

  return run.exited;
}

if (import.meta.main) {
  const exitCode = await runRelatedTests(process.argv.slice(2), process.cwd());

  process.exit(exitCode);
}
