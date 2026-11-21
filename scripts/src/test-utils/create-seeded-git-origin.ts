import { mkdir } from 'node:fs/promises';
import { join } from 'node:path';
import { createGitOrigin, readGitEnv, runGit } from '@zgeoff/testing/git';

export interface GitOrigin {
  readonly origin: string;
  readonly seed: string;

  readonly env: Readonly<Record<string, string>>;

  readonly git: (args: readonly string[]) => Promise<string>;
}

// The kit's empty bare origin, plus a seed repository whose `origin` remote is that origin and a
// runner for git calls in the kit's isolated git environment.
export async function createSeededGitOrigin(directory: string): Promise<GitOrigin> {
  const home = join(directory, 'home');
  const gitEnv = readGitEnv(home);

  const env = Object.fromEntries(
    Object.entries(gitEnv).flatMap(([name, value]) => (value === undefined ? [] : [[name, value]])),
  );

  const git = async (args: readonly string[]) => {
    const output = await runGit(directory, gitEnv, args);

    return output.trim();
  };

  const origin = await createGitOrigin(gitEnv);

  const seed = join(directory, 'seed');

  await mkdir(home, { recursive: true });
  await git(['init', '-q', '-b', 'main', seed]);
  await git(['-C', seed, 'remote', 'add', 'origin', origin.path]);

  return { origin: origin.path, seed, env, git };
}
