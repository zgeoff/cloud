import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { runProcess } from '../run-process.ts';
import { applyReleasePins } from './apply-release-pins.ts';
import { collectPinFiles } from './collect-pin-files.ts';
import type { PinValues } from './collect-pin-values.ts';
import { collectPinValues } from './collect-pin-values.ts';
import { findPinMatch } from './find-pin-match.ts';
import { isNewerVersion } from './is-newer-version.ts';
import { openReleaseBumpPR } from './open-release-bump-pr.ts';
import { parseReleaseVersion } from './parse-release-version.ts';
import { planBumpLabels } from './plan-bump-labels.ts';
import type { ReleaseValues } from './plan-pin-edits.ts';
import { planPinEdits } from './plan-pin-edits.ts';
import { readImageDigest } from './read-image-digest.ts';
import type { PublishedImage, ReleaseRecord } from './release-registry.ts';
import { releaseRegistry } from './release-registry.ts';
import { renderPublishedImagesBody } from './render-published-images-body.ts';
import type { BumpContext } from './types.ts';

// Opens or updates release-check/<dependency>, which pins the images this repository just published:
// each tag from the checked-out commit, and its digest from GHCR, which docker must be signed in to.
// `bun scripts/release/run-published-images-bump.ts <dependency>`
export async function runPublishedImagesBump(
  context: BumpContext,
  args: readonly string[],
): Promise<number> {
  const records = releaseRegistry.filter((each) => each.source.kind === 'published-images');
  const record = records.find((each) => each.name === args[0]);
  const images = record?.source.kind === 'published-images' ? record.source.images : undefined;

  if (args.length !== 1 || record === undefined || images === undefined) {
    const names = records.map((each) => each.name).join('|');

    context.printErr(`usage: run-published-images-bump.ts <${names}>\n`);

    return 2;
  }

  const bump = await readBump(context, record, images);

  if (bump instanceof Error) {
    context.printErr(`${bump.message}\n`);

    return 1;
  }

  return openReleaseBumpPR(context, {
    dependency: record.name,
    version: bump.version,
    labels: bump.labels,
    body: renderPublishedImagesBody({
      record,
      version: bump.version,
      held: bump.held,
      planned: bump.planned,
      labels: bump.labels,
      runURL: findRunURL(context.env),
    }),
    applyPins: () =>
      applyReleasePins({
        record,
        version: bump.version,
        values: bump.values,
        root: context.cwd,
        run: context.run,
        env: context.env,
        printOut: context.printOut,
      }),
  });
}

interface Bump {
  readonly version: string;
  readonly values: ReleaseValues;
  readonly labels: readonly string[];

  // each pin's values on the checkout, and after the bump
  readonly held: PinValues;
  readonly planned: PinValues;
}

// Reads the tags and their digests, and plans the pins once before the branch is built, so a pin
// that cannot move fails here and the body names what the bump changes
async function readBump(
  context: BumpContext,
  record: ReleaseRecord,
  images: readonly PublishedImage[],
): Promise<Bump | Error> {
  const files = await loadFiles(context.cwd, [
    ...images.map((image) => image.file),
    ...collectPinFiles(record),
  ]);

  const values = await readValues(context, files, images);

  const version = values instanceof Error ? '' : (values.tags?.[images[0]?.image ?? ''] ?? '');
  const held = collectPinValues(record, files);

  if (values instanceof Error || held instanceof Error) {
    return values instanceof Error ? values : held;
  }

  const plan = planPinEdits({ record, version, values, files });

  const planned =
    plan instanceof Error ? plan : collectPinValues(record, { ...files, ...plan.files });

  const labels = planLabels(version, record, held);

  if (planned instanceof Error || labels instanceof Error) {
    return planned instanceof Error ? planned : labels;
  }

  return { version, values, labels, held, planned };
}

async function readValues(
  context: BumpContext,
  files: Readonly<Record<string, string>>,
  images: readonly PublishedImage[],
): Promise<ReleaseValues | Error> {
  const tags: Record<string, string> = {};
  const digests: Record<string, string> = {};

  for (const image of images) {
    const match = findPinMatch(files, image);

    const digest =
      match instanceof Error
        ? match
        : await readImageDigest(
            context.run,
            `ghcr.io/zgeoff/${image.image}:${match.groups['tag'] ?? ''}`,
          );

    if (match instanceof Error || digest instanceof Error) {
      return match instanceof Error ? match : digest;
    }

    tags[image.image] = match.groups['tag'] ?? '';
    digests[image.image] = digest;
  }

  return { tags, digests };
}

// A pin's release version that moves rates the bump as the release check rates it. A bump that
// moves no release version, such as a new backup image revision alone, has no update type to rate,
// so it waits for a review.
function planLabels(version: string, record: ReleaseRecord, held: PinValues) {
  const pinned = record.pins.flatMap((pin) => {
    const each = held[pin.id]?.['version'];

    return each === undefined ? [] : [each];
  });

  const target = parseReleaseVersion(version);

  const moves = pinned.some((each) => {
    const from = parseReleaseVersion(each);

    return target !== undefined && from !== undefined && isNewerVersion(target, from);
  });

  return moves ? planBumpLabels(version, pinned, []) : ['needs-review'];
}

async function loadFiles(root: string, paths: readonly string[]) {
  const entries = await Promise.all(
    [...new Set(paths)].map(async (path) => {
      const contents = await readFile(join(root, path), 'utf8').catch(() => null);

      return contents === null ? [] : [[path, contents] as const];
    }),
  );

  return Object.fromEntries(entries.flat());
}

// the Actions run that published the images, from the variables its runner sets
function findRunURL(env: Readonly<Record<string, string | undefined>>) {
  const server = env['GITHUB_SERVER_URL'] ?? '';
  const repository = env['GITHUB_REPOSITORY'] ?? '';
  const runID = env['GITHUB_RUN_ID'] ?? '';

  return server === '' || repository === '' || runID === ''
    ? undefined
    : `${server}/${repository}/actions/runs/${runID}`;
}

if (import.meta.main) {
  process.exitCode = await runPublishedImagesBump(
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
