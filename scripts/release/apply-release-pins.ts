import { chmod, rename, stat, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { match } from 'ts-pattern';
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

  readonly root: string;
  readonly run: Runner;
  readonly readText: (path: string) => Promise<string>;

  // NIX_GITHUB_TOKEN, when set, is a GitHub token that the lock sends to api.github.com, so a
  // shared runner IP's anonymous rate limit cannot fail it
  readonly env: Readonly<Record<string, string | undefined>>;
  readonly printOut: (text: string) => void;
}

export async function applyReleasePins(
  options: Readonly<ApplyReleasePinsOptions>,
): Promise<Error | undefined> {
  const files = await loadPinFiles(options, options.record);

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

async function loadPinFiles(options: Readonly<ApplyReleasePinsOptions>, record: ReleaseRecord) {
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
      const contents = await options.readText(join(options.root, path)).catch(() => null);

      return contents === null ? [] : [[path, contents] as const];
    }),
  );

  return Object.fromEntries(entries.flat());
}

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

async function writeLockedPins(
  options: Readonly<ApplyReleasePinsOptions>,
  files: Readonly<Record<string, string>>,
  plan: Readonly<PinPlan>,
) {
  await writePinFiles(options.root, plan.files, Object.keys(plan.files));

  const locked = await runLocks(options, plan.written);

  const lockFiles = plan.written.flatMap((pin) =>
    pin.lock === undefined ? [] : [pin.lock.lockFile],
  );

  // put every file back, so no pin moves without its lock
  if (locked instanceof Error) {
    await writePinFiles(options.root, files, [...Object.keys(plan.files), ...lockFiles]);
  }

  return locked;
}

async function writePinFiles(
  root: string,
  contents: Readonly<Record<string, string>>,
  paths: readonly string[],
) {
  await Promise.all(paths.map((path) => writePinFile(join(root, path), contents[path] ?? '')));
}

async function writePinFile(path: string, contents: string) {
  const stats = await stat(path);

  await writeFile(`${path}.new`, contents);
  await chmod(`${path}.new`, stats.mode);

  // only the rename replaces the file, so a failed write leaves it as it was
  await rename(`${path}.new`, path);
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

function runLock(options: Readonly<ApplyReleasePinsOptions>, lock: PinLock) {
  return match(lock)
    .with({ kind: 'nix-flake-lock' }, (flakeLock) => runFlakeLock(options, flakeLock))
    .with({ kind: 'bun-lock' }, (bunLock) => runBunLock(options, bunLock))
    .exhaustive();
}

type FlakeLock = Extract<PinLock, { readonly kind: 'nix-flake-lock' }>;

const nixImageFile = join(import.meta.dir, '../nix-image.sh');

async function runFlakeLock(options: Readonly<ApplyReleasePinsOptions>, lock: FlakeLock) {
  const pins = await options.readText(nixImageFile);

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

      // docker takes NIX_CONFIG by name, so the token stays out of every argv and log line
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

async function checkLockedCommit(options: Readonly<ApplyReleasePinsOptions>, lock: FlakeLock) {
  const text = await options.readText(join(options.root, lock.lockFile));

  const nodes = findJSONField(JSON.parse(text), 'nodes');
  const locked = findJSONField(findJSONField(nodes, lock.input), 'locked');
  const rev = findJSONField(locked, 'rev');

  return rev === options.values.commit
    ? undefined
    : new Error(
        `${lock.lockFile} locks ${lock.input} at ${String(rev)}, want ${options.values.commit ?? 'the release commit'}`,
      );
}

type BunLock = Extract<PinLock, { readonly kind: 'bun-lock' }>;

// the release-age gate in bunfig.toml excludes the package, so its release locks on the day it
// publishes; the package's own dependencies stay behind the gate
async function runBunLock(options: Readonly<ApplyReleasePinsOptions>, lock: BunLock) {
  const locked = await runChecked(options.run, ['bun', 'install', '--lockfile-only'], {
    cwd: options.root,
    env: options.env,
  });

  return locked instanceof Error ? locked : checkLockedVersion(options, lock);
}

async function checkLockedVersion(options: Readonly<ApplyReleasePinsOptions>, lock: BunLock) {
  const text = await options.readText(join(options.root, lock.lockFile));

  // bun.lock is JSON with trailing commas, which JSON.parse refuses; each package's entry starts
  // with the name and version it resolved to
  const packages = findJSONField(Bun.JSONC.parse(text), 'packages');
  const entry = findJSONField(packages, lock.packageName);
  const resolved: unknown = Array.isArray(entry) ? entry.at(0) : undefined;

  const version =
    typeof resolved === 'string' && resolved.startsWith(`${lock.packageName}@`)
      ? resolved.slice(lock.packageName.length + 1)
      : undefined;

  return version === options.version
    ? undefined
    : new Error(
        `${lock.lockFile} locks ${lock.packageName} at ${version ?? 'no version'}, want ${options.version}`,
      );
}
