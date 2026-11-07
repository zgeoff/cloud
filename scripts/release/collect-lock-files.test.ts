import { expect, test } from 'bun:test';
import { collectLockFiles } from './collect-lock-files.ts';

test.each([
  [
    'a flake lock',
    { kind: 'nix-flake-lock', flake: 'nixos', input: 'imp', lockFile: 'nixos/flake.lock' } as const,
    ['nixos/flake.lock'],
  ],
  [
    'a bun lock',
    { kind: 'bun-lock', packageName: '@heynixie/contract', lockFile: 'bun.lock' } as const,
    ['bun.lock'],
  ],
  [
    'the restore Jobs',
    {
      kind: 'restore-jobs',
      lockFiles: ['deploy/files/restore-job.yaml', 'images/atc-gateway/restore-job.yaml'],
    } as const,
    ['deploy/files/restore-job.yaml', 'images/atc-gateway/restore-job.yaml'],
  ],
])('it lists the files that %s writes', (_label, lock, expected) => {
  expect(collectLockFiles(lock)).toStrictEqual(expected);
});

test('it lists no file for a pin with no lock', () => {
  expect(collectLockFiles(undefined)).toStrictEqual([]);
});
