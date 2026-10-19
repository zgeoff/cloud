import { onTestFinished } from 'bun:test';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import type { GitOrigin } from './create-git-origin.ts';
import { createGitOrigin } from './create-git-origin.ts';

export interface CloudCheckout extends GitOrigin {
  readonly clone: string;
}

export async function createCloudCheckout(
  files: Readonly<Record<string, string>>,
): Promise<CloudCheckout> {
  const directory = await mkdtemp(join(tmpdir(), 'cloud-checkout-'));

  // the directory goes when the test finishes, so this must run inside a test
  onTestFinished(() => rm(directory, { recursive: true, force: true }));

  const origin = await createGitOrigin(directory);

  const clone = join(directory, 'clone');

  await Promise.all(
    Object.entries(files).map(async (entry: readonly [string, string]) => {
      await mkdir(dirname(join(origin.seed, entry[0])), { recursive: true });
      await writeFile(join(origin.seed, entry[0]), entry[1]);
    }),
  );

  await origin.git(['-C', origin.seed, 'add', '-A']);
  await origin.git(['-C', origin.seed, 'commit', '-qm', 'add the pins']);
  await origin.git(['-C', origin.seed, 'push', '-q', 'origin', 'main']);
  await origin.git(['clone', '-q', origin.origin, clone]);

  return { ...origin, clone };
}
