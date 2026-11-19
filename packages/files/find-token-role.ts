import { timingSafeEqual } from 'node:crypto';
import type { Role } from './types.ts';

// the SHA-256 of each token, as 64 lowercase hex characters; the service never holds a token
export interface TokenHashes {
  readonly owner: string;

  // one per agent token, such as one for each repo's agents
  readonly agent: readonly string[];
}

// each comparison takes the same time whatever the hash holds, and every hash is compared, so the
// timing leaks nothing about which hash matched
export function findTokenRole(authorization: string | null, hashes: TokenHashes): Role | undefined {
  const token = /^Bearer (?<token>\S+)$/u.exec(authorization ?? '')?.groups?.['token'];

  if (token === undefined) {
    return undefined;
  }

  const digest = new Bun.CryptoHasher('sha256').update(token).digest();

  const isOwner = timingSafeEqual(digest, Buffer.from(hashes.owner, 'hex'));

  const isAgent = hashes.agent
    .map((hash) => timingSafeEqual(digest, Buffer.from(hash, 'hex')))
    .includes(true);

  if (isOwner) {
    return 'owner';
  }

  return isAgent ? 'agent' : undefined;
}
