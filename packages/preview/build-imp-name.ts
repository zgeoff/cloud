import { createHash } from 'node:crypto';

export function buildImpName(repo: string, number: number): string {
  // impd names are DNS labels of at most 31 characters and the service's token matches `pv-*`, so
  // the name holds a hash of the repository, which keeps two repositories' pull requests apart
  const repoHash = createHash('sha256').update(repo.toLowerCase()).digest('hex').slice(0, 8);

  return `pv-${repoHash}-${number}`;
}
