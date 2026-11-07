import { match } from 'ts-pattern';
import type { PinLock } from './release-registry.ts';

export function collectLockFiles(lock: PinLock | undefined): readonly string[] {
  if (lock === undefined) {
    return [];
  }

  return match(lock)
    .with({ kind: 'nix-flake-lock' }, { kind: 'bun-lock' }, (each) => [each.lockFile])
    .with({ kind: 'restore-jobs' }, (each) => each.lockFiles)
    .exhaustive();
}
