import { appendFile, mkdir, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { findJSONField } from '../find-json-field.ts';
import { toShellArg } from '../to-shell-arg.ts';
import type { StubImpScenario } from './build-stub-imp.ts';
import { buildStubImp } from './build-stub-imp.ts';

export interface StubImpCLI {
  readonly bin: string;

  readonly readState: () => Promise<Required<Pick<StubImpScenario, 'images' | 'imps'>>>;

  readonly readCalls: () => Promise<readonly (readonly string[])[]>;
}

export async function createStubImpCLI(
  directory: string,
  scenario: Readonly<Pick<StubImpScenario, 'images' | 'imps'>>,
): Promise<StubImpCLI> {
  const bin = join(directory, 'bin');
  const state = join(directory, 'imp-state.json');
  const calls = join(directory, 'imp-calls');

  await mkdir(bin, { recursive: true });

  // each call runs over the state file, so the images and imps outlive the call
  await writeFile(state, JSON.stringify({ images: scenario.images, imps: scenario.imps ?? [] }));
  await writeFile(calls, '');

  const script = `#!/usr/bin/env bash
export STUB_IMP_STATE=${toShellArg(state)} STUB_IMP_CALLS=${toShellArg(calls)}
exec bun ${toShellArg(import.meta.path)} "$@"
`;

  await writeFile(join(bin, 'impz'), script, { mode: 0o755 });

  return {
    bin,
    readState: async () => {
      const text = await readFile(state, 'utf8');

      return parseState(text);
    },
    readCalls: async () => {
      const text = await readFile(calls, 'utf8');

      return text
        .split('\n')
        .filter((line) => line !== '')
        .map((line) => parseArgv(line));
    },
  };
}

function parseState(text: string): Required<Pick<StubImpScenario, 'images' | 'imps'>> {
  const value: unknown = JSON.parse(text);

  return {
    images: toRecords(findJSONField(value, 'images'), ['name', 'digest']).map((record) => ({
      name: record['name'] ?? '',
      digest: record['digest'] ?? '',
    })),
    imps: toRecords(findJSONField(value, 'imps'), ['name', 'image']).map((record) => ({
      name: record['name'] ?? '',
      image: record['image'] ?? '',
    })),
  };
}

function toRecords(
  value: unknown,
  keys: readonly string[],
): readonly Readonly<Record<string, string>>[] {
  // the state file is the stand-in's own, so a value of another shape is a bug in it
  if (!Array.isArray(value)) {
    throw new TypeError(`the stub imp state holds ${JSON.stringify(value)}, not a list`);
  }

  return value.map((item: unknown) =>
    Object.fromEntries(keys.map((key) => [key, toText(findJSONField(item, key))])),
  );
}

function parseArgv(line: string): readonly string[] {
  const value: unknown = JSON.parse(line);

  if (!Array.isArray(value)) {
    throw new TypeError(`the stub imp log holds ${line}, not an argv`);
  }

  return value.map((item: unknown) => toText(item));
}

function toText(value: unknown) {
  if (typeof value !== 'string') {
    throw new TypeError(`the stub imp files hold ${JSON.stringify(value)}, not a string`);
  }

  return value;
}

async function runStubImpCall(argv: readonly string[]) {
  const statePath = process.env['STUB_IMP_STATE'] ?? '';

  await appendFile(process.env['STUB_IMP_CALLS'] ?? '', `${JSON.stringify(argv)}\n`);

  const text = await readFile(statePath, 'utf8');

  const imp = buildStubImp(parseState(text));

  // the stand-in answers every imp call, so the answer is never undefined
  const answer = await imp.handler({ argv: ['impz', ...argv], stdin: '', options: {} });

  await writeFile(statePath, JSON.stringify({ images: imp.images, imps: imp.imps }));

  process.stdout.write(answer?.stdout ?? '');
  process.stderr.write(answer?.stderr ?? '');

  return answer?.exitCode ?? 0;
}

if (import.meta.main) {
  process.exitCode = await runStubImpCall(process.argv.slice(2));
}
