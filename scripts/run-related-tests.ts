// Runs the tests that sit beside the given files: a test file runs itself,
// and a source file runs its sibling test file. Prints a line and exits 0
// when none of the files has a test.
import { existsSync } from 'node:fs';
import { dirname, join, relative } from 'node:path';

// Test files related to the given paths, ordered and deduplicated: a .test.ts selects itself;
// another .ts (not .d.ts) selects its sibling .test.ts. Paths resolve against cwd.
export function collectRelatedTests(paths: readonly string[], cwd: string): string[] {
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

// Runs the related tests, or prints a note and returns 0 when there are none. A test in a package
// with its own bunfig.toml runs from that package under its preload; the rest run through the
// repo's test script. Returns the first failing exit code, or 0.
export async function runRelatedTests(paths: readonly string[], cwd: string): Promise<number> {
  const tests = collectRelatedTests(paths, cwd);

  if (tests.length === 0) {
    process.stdout.write('run-related-tests: no related tests\n');

    return 0;
  }

  for (const [packageDir, packageTests] of Map.groupBy(tests, (test) =>
    findPackageDir(test, cwd),
  )) {
    // one run at a time: the runs share the tree and its ports
    // oxlint-disable-next-line no-await-in-loop
    const exitCode = await runTests(cwd, packageDir, packageTests);

    if (exitCode !== 0) {
      return exitCode;
    }
  }

  return 0;
}

// the nearest directory below cwd, relative to it, that holds the test and its own bunfig.toml
function findPackageDir(test: string, cwd: string): string | undefined {
  for (let dir = dirname(test); dir !== '.' && dir !== '/'; dir = dirname(dir)) {
    if (existsSync(join(cwd, dir, 'bunfig.toml'))) {
      return dir;
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
