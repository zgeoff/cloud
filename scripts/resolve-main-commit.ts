import { ExitError } from './exit-error.ts';
import type { ScriptIO } from './run-or-exit.ts';
import { runOrExit } from './run-or-exit.ts';

export interface MainCommit {
  readonly sha: string;
  readonly short: string;
}

export async function resolveMainCommit(
  io: Readonly<ScriptIO>,
  cwd: string,
  commit: string,
): Promise<MainCommit> {
  await runOrExit(io, ['git', 'fetch', '-q', 'origin', 'main'], { cwd });

  const resolved = await runOrExit(io, ['git', 'rev-parse', '--verify', `${commit}^{commit}`], {
    cwd,
  });

  const sha = resolved.stdout.toString().trim();

  const ancestor = await io.run(['git', 'merge-base', '--is-ancestor', sha, 'origin/main'], {
    cwd,
  });

  if (ancestor.exitCode !== 0) {
    throw new ExitError(1, `${sha} is not on origin/main: build only a commit that main holds`);
  }

  const abbreviated = await runOrExit(io, ['git', 'rev-parse', '--short', sha], { cwd });

  return { sha, short: abbreviated.stdout.toString().trim() };
}
