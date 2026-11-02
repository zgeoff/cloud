import { readFile } from 'node:fs/promises';
import { applyReleasePins } from './apply-release-pins.ts';
import { openReleaseBumpPR } from './open-release-bump-pr.ts';
import { planBumpLabels } from './plan-bump-labels.ts';
import type { ReleaseValues } from './plan-pin-edits.ts';
import type { ReleaseRead } from './read-release-values.ts';
import { readReleaseValues } from './read-release-values.ts';
import type { ReleaseRecord } from './release-registry.ts';
import { releaseRegistry } from './release-registry.ts';
import { renderBumpBody } from './render-bump-body.ts';
import type { BumpContext } from './types.ts';

export async function runReleaseBump(
  context: BumpContext,
  line: readonly string[],
): Promise<number> {
  const [dependency = '', version = '', ...pinned] = line;
  const record = findBumpRecord(dependency, pinned.length);

  if (record instanceof Error) {
    context.printErr(`${record.message}\n`);

    return 2;
  }

  const bump = await readBump({ record, version, pinned, run: context.run });

  if (bump instanceof Error) {
    context.printErr(`${bump.message}\n`);

    return 1;
  }

  return openReleaseBumpPR(context, {
    dependency,
    version,
    labels: bump.labels,
    body: renderBumpBody({ record, version, pinned, labels: bump.labels }),
    applyPins: () =>
      applyReleasePins({
        record,
        version,
        values: bump.values,
        root: context.cwd,
        run: context.run,
        readText: (path) => readFile(path, 'utf8'),
        env: context.env,
        printOut: context.printOut,
      }),
  });
}

function findBumpRecord(dependency: string, count: number): ReleaseRecord | Error {
  const record = releaseRegistry.find((each) => each.name === dependency);

  if (record === undefined) {
    return new Error(`not a release check dependency: '${dependency}'`);
  }

  return record.pins.length === count
    ? record
    : new Error(
        `${dependency} has ${record.pins.length} pins, but ${count} pinned versions were given`,
      );
}

interface Bump {
  readonly values: ReleaseValues;
  readonly labels: readonly string[];
}

async function readBump(read: ReleaseRead): Promise<Bump | Error> {
  const result = await readReleaseValues(read);

  if (result instanceof Error) {
    return result;
  }

  const labels = planBumpLabels(read.version, read.pinned, result.flags);

  return labels instanceof Error ? labels : { values: result.values, labels };
}
