import { requireVariable } from './require-variable.ts';
import type { Environment } from './types.ts';

interface GHCRPullValues {
  readonly username: string;
  readonly token: string;
}

const pullNeed =
  "the atc gateway's images are private, so .env must reference op://cloud/ghcr-pull";

export function requireGHCRPullCredential(env: Environment): GHCRPullValues {
  const username = requireVariable(env, 'GHCR_PULL_USERNAME', pullNeed);
  const token = requireVariable(env, 'GHCR_PULL_TOKEN', pullNeed);

  // either value goes into the registry's basic auth, so each must be one word
  if (/[\s:]/u.test(username)) {
    throw new Error('GHCR_PULL_USERNAME must be the one GitHub login, with no whitespace or colon');
  }

  if (/\s/u.test(token)) {
    throw new Error('GHCR_PULL_TOKEN must be the one token, with no whitespace');
  }

  return { username, token };
}
