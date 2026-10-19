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
import { runChecked } from './run-checked.ts';
import { runGitSteps } from './run-git-steps.ts';
import { toRunOptions } from './to-run-options.ts';
import type { BumpContext } from './types.ts';

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

  const moved = await findMovedTags(context, images);

  if (moved !== undefined) {
    const print = moved instanceof Error ? context.printErr : context.printOut;

    print(`${moved.message}\n`);

    return moved instanceof Error ? 1 : 0;
  }

  const bump = await readBump(context, record, images);

  if (bump instanceof Error) {
    context.printErr(`${bump.message}\n`);

    return 1;
  }

  // the commit title, which keys a person's hold or rejection, names every image's tag, so a
  // rejected backup revision never holds back the next one at the same gateway version
  const release = images.map((image) => bump.values.tags?.[image.image] ?? '').join('+');

  return openReleaseBumpPR(context, {
    dependency: record.name,
    version: release,
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

async function findMovedTags(
  context: BumpContext,
  images: readonly PublishedImage[],
): Promise<{ readonly message: string } | Error | undefined> {
  const paths = [...new Set(images.map((image) => image.file))];

  const main = await readMainFiles(context, paths);
  const local = await loadFiles(context.cwd, paths);

  if (main instanceof Error) {
    return main;
  }

  const published = collectTags(local, images);
  const current = collectTags(main, images);

  if (published instanceof Error) {
    return published;
  }

  if (current instanceof Error) {
    return current;
  }

  // runs can finish out of commit order, and each rebuilds the one branch from main, so a run whose
  // tags main no longer names leaves the branch to the newer push's run
  return JSON.stringify(published) === JSON.stringify(current)
    ? undefined
    : {
        message: `main names ${Object.values(current).join(' ')}, not the published ${Object.values(published).join(' ')}: the run for main's tags pins them`,
      };
}

async function readMainFiles(context: BumpContext, paths: readonly string[]) {
  const fetched = await runGitSteps(context, [['fetch', '-q', 'origin', 'main']]);

  const files: Record<string, string> = {};

  if (fetched !== undefined) {
    return fetched;
  }

  for (const path of paths) {
    const text = await runChecked(
      context.run,
      ['git', 'show', `origin/main:${path}`],
      toRunOptions(context),
    );

    if (text instanceof Error) {
      return text;
    }

    files[path] = text;
  }

  return files;
}

function collectTags(files: Readonly<Record<string, string>>, images: readonly PublishedImage[]) {
  const tags: Record<string, string> = {};

  for (const image of images) {
    const match = findPinMatch(files, image);

    if (match instanceof Error) {
      return match;
    }

    tags[image.image] = match.groups['tag'] ?? '';
  }

  return tags;
}

interface Bump {
  readonly version: string;
  readonly values: ReleaseValues;
  readonly labels: readonly string[];

  readonly held: PinValues;
  readonly planned: PinValues;
}

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

  if (values instanceof Error) {
    return values;
  }

  const version = values.tags?.[images[0]?.image ?? ''] ?? '';
  const held = collectPinValues(record, files);
  const plan = planPinEdits({ record, version, values, files });

  if (held instanceof Error) {
    return held;
  }

  if (plan instanceof Error) {
    return plan;
  }

  const planned = collectPinValues(record, { ...files, ...plan.files });
  const labels = planLabels(version, record, held);

  if (planned instanceof Error) {
    return planned;
  }

  return labels instanceof Error ? labels : { version, values, labels, held, planned };
}

async function readValues(
  context: BumpContext,
  files: Readonly<Record<string, string>>,
  images: readonly PublishedImage[],
): Promise<ReleaseValues | Error> {
  const tags = collectTags(files, images);
  const digests: Record<string, string> = {};

  if (tags instanceof Error) {
    return tags;
  }

  for (const image of images) {
    const ref = `ghcr.io/zgeoff/${image.image}:${tags[image.image] ?? ''}`;

    // docker must be signed in to GHCR
    const digest = await readImageDigest(context.run, ref);

    if (digest instanceof Error) {
      return digest;
    }

    digests[image.image] = digest;
  }

  return { tags, digests };
}

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

  // a bump that moves no release version, such as a new backup image revision alone, has no update
  // type to rate
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
