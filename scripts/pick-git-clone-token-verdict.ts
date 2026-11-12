// the host check exits 0 for a token that reads the repo, 120 for a file that is absent or
// unreadable, and 121 or 122 for a token that is malformed or that GitHub refuses; any other exit
// is ssh's or an unexpected GitHub answer
export type GitCloneTokenVerdict = 'good' | 'absent' | 'bad' | 'unchecked';

export function pickGitCloneTokenVerdict(exitCode: number): GitCloneTokenVerdict {
  if (exitCode === 0) {
    return 'good';
  }

  if (exitCode === 120) {
    return 'absent';
  }

  return exitCode === 121 || exitCode === 122 ? 'bad' : 'unchecked';
}
