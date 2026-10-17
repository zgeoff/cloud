import { readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { collectPinFiles } from './collect-pin-files.ts';
import { findPinTableMismatches } from './find-pin-table-mismatches.ts';
import { pinTableFile } from './pin-table-file.ts';
import { planPinTable } from './plan-pin-table.ts';
import { releaseRegistry } from './release-registry.ts';

export interface CheckReleasePinsOptions {
  // the root of the zgeoff/cloud checkout
  readonly root: string;
  readonly args: readonly string[];
  readonly printOut: (text: string) => void;
  readonly printErr: (text: string) => void;
}

// CI's check that every registry pin in the checkout matches the pin table. With --write it
// rewrites the table from the pins instead, for a pin that a person edits by hand.
export async function checkReleasePins(
  options: Readonly<CheckReleasePinsOptions>,
): Promise<number> {
  const files = await loadFiles(options.root);

  if (options.args[0] === '--write') {
    const table = planPinTable(releaseRegistry, files);

    if (table instanceof Error) {
      options.printErr(`check-release-pins: ${table.message}\n`);

      return 1;
    }

    await writeFile(join(options.root, pinTableFile), table);

    return 0;
  }

  return printMismatches(options, findPinTableMismatches(files));
}

async function loadFiles(root: string) {
  const paths = [...new Set(releaseRegistry.flatMap((record) => collectPinFiles(record)))];

  const entries = await Promise.all(
    paths.map(async (path) => {
      const contents = await readFile(join(root, path), 'utf8').catch(() => null);

      return contents === null ? [] : [[path, contents] as const];
    }),
  );

  return Object.fromEntries(entries.flat());
}

function printMismatches(
  options: Readonly<CheckReleasePinsOptions>,
  mismatches: readonly string[],
) {
  if (mismatches.length === 0) {
    options.printOut(`check-release-pins: every pin matches ${pinTableFile}\n`);

    return 0;
  }

  const lines = mismatches.map((mismatch) => `check-release-pins: ${mismatch}\n`).join('');

  options.printErr(
    `${lines}check-release-pins: a bump writes both; after a pin edit by hand, run bun scripts/release/check-release-pins.ts --write\n`,
  );

  return 1;
}

if (import.meta.main) {
  process.exitCode = await checkReleasePins({
    root: process.cwd(),
    args: process.argv.slice(2),
    printOut: (text) => {
      process.stdout.write(text);
    },
    printErr: (text) => {
      process.stderr.write(text);
    },
  });
}
