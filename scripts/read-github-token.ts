import type { Runner } from './run-process.ts';

// The GitHub token that reads the private ghcr.io/zgeoff packages, or undefined when there is
// none. `gh auth token` prints GH_TOKEN or GITHUB_TOKEN when one is set, as CI sets the workflow's
// token, and otherwise the token gh signed in with on a PC, so one lookup serves both.
export async function readGitHubToken(run: Runner): Promise<string | undefined> {
  const result = await run(['gh', 'auth', 'token', '--hostname', 'github.com'], {
    env: { ...process.env, GH_TELEMETRY: '0', DO_NOT_TRACK: '1', GH_NO_UPDATE_NOTIFIER: '1' },
    timeoutMs: 10_000,
  });

  const token = result.stdout.toString().trim();

  return result.exitCode === 0 && token !== '' ? token : undefined;
}

// what a check prints when readGitHubToken finds none
export const missingGitHubTokenText =
  'no GitHub token to read ghcr.io/zgeoff: set GH_TOKEN, or sign gh in with the read:packages scope';
