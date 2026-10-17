import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { runProcess } from '../run-process.ts';
import { applyReleasePins } from './apply-release-pins.ts';
import { collectPinFiles } from './collect-pin-files.ts';
import { findPinnedVersions } from './find-pinned-versions.ts';
import { readReleaseValues } from './read-release-values.ts';
import type { ReleaseRecord } from './release-registry.ts';
import { releaseRegistry } from './release-registry.ts';
import type { BumpContext } from './types.ts';

// Pins one release by hand in the checkout it runs from, as the bump pull request pins it, and
// opens no pull request: `bun scripts/release/run-release-pin.ts <dependency> <version>`
export async function runReleasePin(
  context: BumpContext,
  args: readonly string[],
): Promise<number> {
  const [dependency = '', version = ''] = args;

  // the workflow that publishes a published-images record's images pins them
  const records = releaseRegistry.filter((each) => each.source.kind !== 'published-images');
  const record = records.find((each) => each.name === dependency);

  if (args.length !== 2 || record === undefined) {
    const names = records.map((each) => each.name).join('|');

    context.printErr(`usage: run-release-pin.ts <${names}> <version>\n`);

    return 2;
  }

  const applied = await applyReleasePin(context, record, version);

  return applied instanceof Error ? printError(context, applied) : 0;
}

function printError(context: BumpContext, error: Readonly<Error>) {
  context.printErr(`${error.message}\n`);

  return 1;
}

async function applyReleasePin(context: BumpContext, record: ReleaseRecord, version: string) {
  const files = await loadPinFiles(context.cwd, collectPinFiles(record));

  const pinned = findPinnedVersions(record, files);

  const read =
    pinned instanceof Error
      ? pinned
      : await readReleaseValues({ record, version, pinned, run: context.run });

  return read instanceof Error
    ? read
    : applyReleasePins({
        record,
        version,
        values: read.values,
        root: context.cwd,
        run: context.run,
        env: context.env,
        printOut: context.printOut,
      });
}

async function loadPinFiles(root: string, paths: readonly string[]) {
  const entries = await Promise.all(
    paths.map(async (path) => {
      const contents = await readFile(join(root, path), 'utf8').catch(() => null);

      return contents === null ? [] : [[path, contents] as const];
    }),
  );

  return Object.fromEntries(entries.flat());
}

if (import.meta.main) {
  process.exitCode = await runReleasePin(
    {
      cwd: process.cwd(),
      env: process.env,
      run: runProcess,
      printOut: (text) => {
        process.stdout.write(text);
      },
      printErr: (text) => {
        process.stderr.write(text);
      },
    },
    process.argv.slice(2),
  );
}
