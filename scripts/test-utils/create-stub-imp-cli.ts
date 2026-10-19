import { appendFile, mkdir, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { findJSONField } from '../find-json-field.ts';
import { toShellArg } from '../to-shell-arg.ts';
import type { StubImpScenario } from './build-stub-imp.ts';
import { buildStubImp } from './build-stub-imp.ts';

// Writes <dir>/bin/impz, an executable stand-in for the impz CLI, for a test that runs a whole
// script as a child process. Each call runs buildStubImp's answers over a state file in <dir>, so
// the images and imps outlive the call, and logs its argv as a JSON line to <dir>/imp-calls.
export interface StubImpCLI {
  // the directory to put first on the script's PATH
  readonly bin: string;

  // the images and imps as the calls left them
  readonly readState: () => Promise<Required<Pick<StubImpScenario, 'images' | 'imps'>>>;

  // each call's argv after `impz`, in order
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

// the state file and the log are the stand-in's own, so a value of another shape is a bug in it
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

// the CLI that <dir>/bin/impz runs: one call over the state file
async function runStubImpCall(argv: readonly string[]) {
  const statePath = process.env['STUB_IMP_STATE'] ?? '';

  await appendFile(process.env['STUB_IMP_CALLS'] ?? '', `${JSON.stringify(argv)}\n`);

  const text = await readFile(statePath, 'utf8');

  const imp = buildStubImp(parseState(text));

  // buildStubImp answers every imp call, so the answer is never undefined
  const answer = await imp.handler({ argv: ['impz', ...argv], stdin: '', options: {} });

  await writeFile(statePath, JSON.stringify({ images: imp.images, imps: imp.imps }));

  process.stdout.write(answer?.stdout ?? '');
  process.stderr.write(answer?.stderr ?? '');

  return answer?.exitCode ?? 0;
}

if (import.meta.main) {
  process.exitCode = await runStubImpCall(process.argv.slice(2));
}
