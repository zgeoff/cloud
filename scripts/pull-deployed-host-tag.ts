import { deployedHostTag } from './constants.ts';
import type { ScriptIO } from './run-or-exit.ts';

// Fetches the tag that marks the commit the host runs, so the host's own target image is read
// from that commit. It throws when the fetch fails.
export async function pullDeployedHostTag(
  io: Readonly<Pick<ScriptIO, 'run'>>,
  clone: string,
): Promise<void> {
  const fetched = await io.run([
    'git',
    '-C',
    clone,
    'fetch',
    '-q',
    'origin',
    `+${deployedHostTag}:${deployedHostTag}`,
  ]);

  if (fetched.exitCode !== 0) {
    throw new Error(`git fetch of deployed/host failed: ${fetched.stderr.toString().trim()}`);
  }
}
