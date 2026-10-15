import { createHash } from 'node:crypto';

// The imp that runs a pull request's preview. impd names are DNS labels of at most 31 characters,
// and its token for the service matches `pv-*`, so the name holds the pull request number and a
// hash of the repository, which keeps two repositories' pull requests of one number apart.
export function buildImpName(repo: string, number: number): string {
  const repoHash = createHash('sha256').update(repo.toLowerCase()).digest('hex').slice(0, 8);

  return `pv-${repoHash}-${number}`;
}
