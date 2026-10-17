import { chmod, readFile, rename, stat, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { findJSONField } from '../find-json-field.ts';
import type { Runner } from '../run-process.ts';
import { collectPinFiles } from './collect-pin-files.ts';
import { pinTableFile } from './pin-table-file.ts';
import type { PinPlan, ReleaseValues } from './plan-pin-edits.ts';
import { planPinEdits } from './plan-pin-edits.ts';
import { planPinTable } from './plan-pin-table.ts';
import type { Pin, PinLock, ReleaseRecord } from './release-registry.ts';
import { runChecked } from './run-checked.ts';

export interface ApplyReleasePinsOptions {
  readonly record: ReleaseRecord;
  readonly version: string;
  readonly values: ReleaseValues;

  // the root of the zgeoff/cloud checkout whose pins it writes
  readonly root: string;
  readonly run: Runner;

  // NIX_GITHUB_TOKEN, when set, is a GitHub token that the lock sends to api.github.com, so a
  // shared runner IP's anonymous rate limit cannot fail it
  readonly env: Readonly<Record<string, string | undefined>>;
  readonly printOut: (text: string) => void;
}

// Writes the release's pins in the checkout, as planPinEdits plans them, then locks each written
// pin's flake input, which must lock the release's commit
export async function applyReleasePins(
  options: Readonly<ApplyReleasePinsOptions>,
): Promise<Error | undefined> {
  const files = await loadPinFiles(options.root, options.record);

  const edits = planPinEdits({
    record: options.record,
    version: options.version,
    values: options.values,
    files,
  });

  const plan = edits instanceof Error ? edits : planTableWrite(options.record, files, edits);

  if (plan instanceof Error) {
    return plan;
  }

  const locked = await writeLockedPins(options, files, plan);

  if (locked instanceof Error) {
    return locked;
  }

  options.printOut(plan.notes.map((note) => `${note}\n`).join(''));

  return undefined;
}

// plans the pin table's new text beside the pin edits, when the record's entries change
function planTableWrite(
  record: ReleaseRecord,
  files: Readonly<Record<string, string>>,
  plan: PinPlan,
): PinPlan | Error {
  const current = files[pinTableFile];

  const table =
    current === undefined
      ? new Error(`${pinTableFile} is missing: run this from the root of a zgeoff/cloud checkout`)
      : planPinTable([record], { ...files, ...plan.files });

  if (table instanceof Error || table === current) {
    return table instanceof Error ? table : plan;
  }

  return { ...plan, files: { ...plan.files, [pinTableFile]: table } };
}

// a failed lock or generator puts every pin file, lock file and generated file back, so no pin
// moves without its lock and the files generated from its release
async function writeLockedPins(
  options: Readonly<ApplyReleasePinsOptions>,
  files: Readonly<Record<string, string>>,
  plan: Readonly<PinPlan>,
) {
  await writePinFiles(options.root, plan.files, Object.keys(plan.files));

  const locked = await runLocks(options, plan.written);

  // the files generated from a release move only with a pin, as a lock does
  const generated =
    locked instanceof Error || plan.written.length === 0 ? locked : await runGenerator(options);

  const lockFiles = plan.written.flatMap((pin) =>
    pin.lock === undefined ? [] : [pin.lock.lockFile],
  );

  // a generated file that the checkout lacked has no contents to put back
  const generatedFiles = (options.record.generated?.files ?? []).filter((path) => path in files);

  if (generated instanceof Error) {
    await writePinFiles(options.root, files, [
      ...Object.keys(plan.files),
      ...lockFiles,
      ...generatedFiles,
    ]);
  }

  return generated;
}

// the release's tag reaches the record's generator, which writes its files in the checkout
async function runGenerator(
  options: Readonly<ApplyReleasePinsOptions>,
): Promise<Error | undefined> {
  const generator = options.record.generated;

  if (generator === undefined) {
    return undefined;
  }

  const tag = `${options.record.tagPrefix}${options.version}`;

  const ran = await runChecked(options.run, ['bun', join(options.root, generator.script), tag], {
    cwd: options.root,
    env: options.env,
  });

  return ran instanceof Error ? ran : undefined;
}

async function runLocks(
  options: Readonly<ApplyReleasePinsOptions>,
  written: readonly Pin[],
): Promise<Error | undefined> {
  for (const pin of written) {
    if (pin.lock !== undefined) {
      const locked = await runLock(options, pin.lock);

      if (locked instanceof Error) {
        return locked;
      }
    }
  }

  return undefined;
}

// the contents of each file the record's pins read or lock; a missing file is left out
async function loadPinFiles(root: string, record: ReleaseRecord) {
  const assetFiles = record.pins.flatMap((pin) =>
    pin.lines.flatMap((line) =>
      Object.values(line.parts).flatMap((part) =>
        part.kind === 'sum' && typeof part.asset !== 'string' ? [part.asset.file] : [],
      ),
    ),
  );

  const paths = new Set([...collectPinFiles(record), ...assetFiles]);

  const entries = await Promise.all(
    [...paths].map(async (path) => {
      const contents = await readFile(join(root, path), 'utf8').catch(() => null);

      return contents === null ? [] : [[path, contents] as const];
    }),
  );

  return Object.fromEntries(entries.flat());
}

async function writePinFiles(
  root: string,
  contents: Readonly<Record<string, string>>,
  paths: readonly string[],
) {
  await Promise.all(paths.map((path) => writePinFile(join(root, path), contents[path] ?? '')));
}

// writes beside the file, then renames over it with its mode, so a failed write leaves it as it was
async function writePinFile(path: string, contents: string) {
  const stats = await stat(path);

  await writeFile(`${path}.new`, contents);
  await chmod(`${path}.new`, stats.mode);
  await rename(`${path}.new`, path);
}

// the Nix image that scripts/nix-image.sh pins, in this script's own checkout
const nixImageFile = new URL('../nix-image.sh', import.meta.url);

// docker takes NIX_CONFIG by name, so the token stays out of every argv and log line; without the
// token, the container gets no NIX_CONFIG at all
async function runLock(options: Readonly<ApplyReleasePinsOptions>, lock: PinLock) {
  const pins = await readFile(nixImageFile, 'utf8');

  const image = /^NIX_IMAGE='(?<image>[^']+)'$/mu.exec(pins)?.groups?.['image'];

  if (image === undefined) {
    return new Error('scripts/nix-image.sh pins no NIX_IMAGE');
  }

  const token = options.env['NIX_GITHUB_TOKEN'] ?? '';
  const caller = options.env['NIX_CONFIG'] ?? '';

  const nixConfig =
    token === ''
      ? undefined
      : `${caller === '' ? '' : `${caller}\n`}access-tokens = github.com=${token}`;

  const owner = `${process.getuid?.() ?? 0}:${process.getgid?.() ?? 0}`;

  const locked = await runChecked(
    options.run,
    [
      'docker',
      'run',
      '--rm',
      '-v',
      `${join(options.root, lock.flake)}:/src`,
      '-w',
      '/src',
      ...(nixConfig === undefined ? [] : ['-e', 'NIX_CONFIG']),
      image,
      'sh',
      '-c',
      `nix --extra-experimental-features 'nix-command flakes' flake lock && chown ${owner} flake.lock`,
    ],
    { env: nixConfig === undefined ? options.env : { ...options.env, NIX_CONFIG: nixConfig } },
  );

  return locked instanceof Error ? locked : checkLockedCommit(options, lock);
}

async function checkLockedCommit(options: Readonly<ApplyReleasePinsOptions>, lock: PinLock) {
  const text = await readFile(join(options.root, lock.lockFile), 'utf8');

  const nodes = findJSONField(JSON.parse(text), 'nodes');
  const locked = findJSONField(findJSONField(nodes, lock.input), 'locked');
  const rev = findJSONField(locked, 'rev');

  return rev === options.values.commit
    ? undefined
    : new Error(
        `${lock.lockFile} locks ${lock.input} at ${String(rev)}, want ${options.values.commit ?? 'the release commit'}`,
      );
}
