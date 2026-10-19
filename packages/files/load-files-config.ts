import type { TokenHashes } from './find-token-role.ts';

export interface FilesConfig {
  readonly port: number;
  readonly dataDir: string;
  readonly publicURL: string;
  readonly tokenHashes: TokenHashes;
}

// The configuration from the environment: FILES_PORT (8080 by default), FILES_DATA_DIR,
// FILES_PUBLIC_URL, and each role token's SHA-256 in hex. A missing or malformed value throws, so
// the service never starts half-configured.
export function loadFilesConfig(env: Readonly<Record<string, string | undefined>>): FilesConfig {
  const agent = requireHash(env, 'FILES_AGENT_TOKEN_SHA256');
  const owner = requireHash(env, 'FILES_OWNER_TOKEN_SHA256');

  if (agent === owner) {
    throw new Error('FILES_AGENT_TOKEN_SHA256 and FILES_OWNER_TOKEN_SHA256 must differ');
  }

  return {
    port: requirePort(env['FILES_PORT'] ?? '8080'),
    dataDir: requireValue(env, 'FILES_DATA_DIR'),
    publicURL: requireOrigin(requireValue(env, 'FILES_PUBLIC_URL')),
    tokenHashes: { agent, owner },
  };
}

function requireValue(env: Readonly<Record<string, string | undefined>>, name: string): string {
  const value = env[name]?.trim() ?? '';

  if (value === '') {
    throw new Error(`${name} is not set`);
  }

  return value;
}

function requireHash(env: Readonly<Record<string, string | undefined>>, name: string): string {
  const value = requireValue(env, name).toLowerCase();

  if (!/^[\da-f]{64}$/u.test(value)) {
    throw new Error(`${name} must be a SHA-256 digest as 64 hex characters`);
  }

  return value;
}

function requirePort(value: string): number {
  const port = Number(value);

  if (!Number.isInteger(port) || port < 1 || port > 65_535) {
    throw new Error('FILES_PORT must be a port number');
  }

  return port;
}

function requireOrigin(value: string): string {
  const url = URL.parse(value);

  if (url === null || !['http:', 'https:'].includes(url.protocol) || url.origin !== value) {
    throw new Error('FILES_PUBLIC_URL must be an http or https origin with no path');
  }

  return url.origin;
}
