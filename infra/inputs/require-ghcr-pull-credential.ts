import { requireVariable } from './require-variable.ts';
import type { Environment } from './types.ts';

interface GHCRPullValues {
  readonly username: string;
  readonly token: string;
}

// why the gateway needs the credential, for requireVariable's error
const pullNeed =
  "the atc gateway's images are private, so .env must reference op://cloud/ghcr-pull";

// The login and classic token k3s pulls the gateway's and the backup's private GHCR images with,
// from GHCR_PULL_USERNAME and GHCR_PULL_TOKEN. Throws unless both are one word, since either goes
// into the registry's basic auth. The error never carries a value.
export function requireGHCRPullCredential(env: Environment): GHCRPullValues {
  const username = requireVariable(env, 'GHCR_PULL_USERNAME', pullNeed);
  const token = requireVariable(env, 'GHCR_PULL_TOKEN', pullNeed);

  if (/[\s:]/u.test(username)) {
    throw new Error('GHCR_PULL_USERNAME must be the one GitHub login, with no whitespace or colon');
  }

  if (/\s/u.test(token)) {
    throw new Error('GHCR_PULL_TOKEN must be the one token, with no whitespace');
  }

  return { username, token };
}
