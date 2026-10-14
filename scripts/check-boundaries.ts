import { stat } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { cruise, format } from 'dependency-cruiser';
import type { ICruiseResult } from 'dependency-cruiser';
import extractDepcruiseOptions from 'dependency-cruiser/config-utl/extract-depcruise-options';

// Checks the import boundaries that .dependency-cruiser.json declares: the direction between
// infra's groups, and no relative import into another workspace package. Prints each violation:
// 0 when there is none, 1 on a violation, 2 on a bad argument.
export interface CheckBoundariesOptions {
  readonly args: readonly string[];
  readonly printOut: (text: string) => void;
  readonly printErr: (text: string) => void;
}

const usage = 'usage: check-boundaries.ts [repo root]\n';

// the repo's own rules, whichever root the check reads
const configFile = join(import.meta.dir, '..', '.dependency-cruiser.json');

// the folders that hold the repo's TypeScript; the generated SDK stays out
const sourceFolders = ['infra', 'packages', 'workers', 'scripts', 'e2e', 'test-support'];

export async function checkBoundaries(options: Readonly<CheckBoundariesOptions>): Promise<number> {
  if (options.args.length > 1) {
    options.printErr(usage);

    return 2;
  }

  const result = await loadImportGraph(resolve(options.args[0] ?? '.'));

  if (result.summary.error > 0) {
    const report = await format(result, { outputType: 'err' });

    options.printErr(report.output as string);

    return 1;
  }

  options.printOut(
    `check-boundaries: ${result.summary.totalCruised} modules hold every boundary\n`,
  );

  return 0;
}

async function loadImportGraph(root: string): Promise<ICruiseResult> {
  const folders = await collectSourceFolders(root);
  const cruiseOptions = await extractDepcruiseOptions(configFile);
  const cruised = await cruise(folders, { ...cruiseOptions, baseDir: root });

  return cruised.output as ICruiseResult;
}

async function collectSourceFolders(root: string): Promise<string[]> {
  const present = await Promise.all(
    sourceFolders.map((folder) =>
      stat(join(root, folder))
        .then((found) => found.isDirectory())
        .catch(() => false),
    ),
  );

  return sourceFolders.filter((_, index) => present[index]);
}

if (import.meta.main) {
  process.exitCode = await checkBoundaries({
    args: process.argv.slice(2),
    printOut: (text) => process.stdout.write(text),
    printErr: (text) => process.stderr.write(text),
  });
}
