import { writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import type { StubAnswer, StubCall, StubHandler } from './build-stub-runner.ts';

// Stands in for the lock-only install that the release bump runs, checked against bun 1.4.3 on
// 2026-10-29: it writes bun.lock in its working directory, or exits 1 with the resolve error on
// stderr
export interface StubBunInstallScenario {
  readonly lock?: string;
  readonly error?: string;
}

export function buildStubBunInstall(scenario: StubBunInstallScenario): StubHandler {
  const answerCall: StubHandler = (call) =>
    isLockOnlyInstall(call) ? writeLock(scenario, call) : undefined;

  return answerCall;
}

function isLockOnlyInstall(call: StubCall) {
  return (
    call.options.cwd !== undefined &&
    call.argv.length === 3 &&
    call.argv[0] === 'bun' &&
    call.argv[1] === 'install' &&
    call.argv[2] === '--lockfile-only'
  );
}

async function writeLock(scenario: StubBunInstallScenario, call: StubCall): Promise<StubAnswer> {
  if (scenario.error !== undefined) {
    return { exitCode: 1, stderr: `${scenario.error}\n` };
  }

  await writeFile(join(call.options.cwd ?? '', 'bun.lock'), scenario.lock ?? '');

  return {};
}
