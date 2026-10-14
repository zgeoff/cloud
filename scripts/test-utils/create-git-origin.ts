import { mkdir } from 'node:fs/promises';
import { join } from 'node:path';
import { runProcess } from '../run-process.ts';

export interface GitOrigin {
  // the bare repository, and a working repository whose origin it is
  readonly origin: string;
  readonly seed: string;

  // the environment every git call of the test runs with: no global or system config
  readonly env: Readonly<Record<string, string>>;

  // runs real git with that environment and returns its trimmed stdout; a failure throws
  readonly git: (args: readonly string[]) => Promise<string>;
}

// Creates a real bare repository at <dir>/origin.git and a working repository at <dir>/seed whose
// origin it is, both on main, for a test whose script fetches from and pushes to an origin
export async function createGitOrigin(dir: string): Promise<GitOrigin> {
  const home = join(dir, 'home');

  const env = {
    PATH: process.env['PATH'] ?? '/usr/bin:/bin',
    HOME: home,
    GIT_CONFIG_GLOBAL: '/dev/null',
    GIT_CONFIG_NOSYSTEM: '1',
    GIT_AUTHOR_NAME: 'test',
    GIT_AUTHOR_EMAIL: 'test@example.invalid',
    GIT_COMMITTER_NAME: 'test',
    GIT_COMMITTER_EMAIL: 'test@example.invalid',
  };

  const git = makeGit(env);
  const origin = join(dir, 'origin.git');
  const seed = join(dir, 'seed');

  await mkdir(home, { recursive: true });
  await git(['init', '-q', '--bare', '-b', 'main', origin]);
  await git(['init', '-q', '-b', 'main', seed]);
  await git(['-C', seed, 'remote', 'add', 'origin', origin]);

  return { origin, seed, env, git };
}

function makeGit(env: Readonly<Record<string, string>>) {
  return async (args: readonly string[]) => {
    const result = await runProcess(['git', ...args], { env });

    if (result.exitCode !== 0) {
      throw new Error(
        `git ${args.join(' ')} exited ${result.exitCode}: ${result.stderr.toString()}`,
      );
    }

    return result.stdout.toString().trim();
  };
}
