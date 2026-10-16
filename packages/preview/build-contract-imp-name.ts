import { createHash } from 'node:crypto';

// Every contract run's imp starts with this, inside the service token's `pv-*`, and no preview's
// imp does, since a preview's name holds a hex hash where this holds `sdk`
export const contractImpPrefix = 'pv-sdk-';

// The imp that runs the SDK contract suite at one head commit. impd names are DNS labels of at most
// 31 characters, so the name holds a hash of the repository and the commit.
export function buildContractImpName(repo: string, headSHA: string): string {
  const hash = createHash('sha256')
    .update(`${repo.toLowerCase()}@${headSHA}`)
    .digest('hex')
    .slice(0, 16);

  return `${contractImpPrefix}${hash}`;
}
