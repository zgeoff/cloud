import { timingSafeEqual } from 'node:crypto';
import type { Role } from './types.ts';

// the SHA-256 of each role token, as 64 lowercase hex characters; the service never holds a token
export type TokenHashes = Readonly<Record<Role, string>>;

const roles: readonly Role[] = ['owner', 'agent'];

// The role whose token the Authorization header carries as a bearer token, or undefined for no
// header, another scheme, or a token whose hash matches neither role. Each comparison takes the
// same time whatever the hash holds.
export function findTokenRole(authorization: string | null, hashes: TokenHashes): Role | undefined {
  const token = /^Bearer (?<token>\S+)$/u.exec(authorization ?? '')?.groups?.['token'];

  if (token === undefined) {
    return undefined;
  }

  const digest = new Bun.CryptoHasher('sha256').update(token).digest();

  return roles.find((role) => timingSafeEqual(digest, Buffer.from(hashes[role], 'hex')));
}
