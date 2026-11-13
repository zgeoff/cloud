import { mkdir, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

// Compiles the entries as the image does, then runs the compiled API's `passkeys` command on an
// empty auth folder. A bundle that stops at start, such as one whose bundler drops a library's
// start-up code, fails here before it reaches an image. Run it after `bun install` in this folder.
//
//   bun check-api-binary.ts
const workDirectory = await mkdtemp(join(tmpdir(), 'pepys-api-binary-'));

try {
  const binDirectory = join(workDirectory, 'bin');
  const authDirectory = join(workDirectory, 'auth');

  await mkdir(authDirectory);

  const compile = Bun.spawnSync(
    [process.execPath, join(import.meta.dir, 'compile-entries.ts'), binDirectory],
    {
      stdio: ['ignore', 'inherit', 'inherit'],
    },
  );

  if (compile.exitCode !== 0) {
    throw new Error(`compile-entries.ts exited ${compile.exitCode}`);
  }

  const passkeys = Bun.spawnSync([join(binDirectory, 'pepys-api'), 'passkeys'], {
    env: { PATH: process.env['PATH'] ?? '', PEPYS_AUTH_DIR: authDirectory },
    stdio: ['ignore', 'inherit', 'inherit'],
  });

  if (passkeys.exitCode !== 0) {
    throw new Error(`the compiled pepys-api exited ${passkeys.exitCode} on passkeys`);
  }
} finally {
  await rm(workDirectory, { recursive: true, force: true });
}
