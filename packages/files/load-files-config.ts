import type { TokenHashes } from './find-token-role.ts';

export interface FilesConfig {
  readonly port: number;
  readonly dataDir: string;
  readonly publicURL: string;
  readonly tokenHashes: TokenHashes;
}

export function loadFilesConfig(env: Readonly<Record<string, string | undefined>>): FilesConfig {
  const agent = requireHashList(env, 'FILES_AGENT_TOKEN_SHA256');
  const owner = requireHash(env, 'FILES_OWNER_TOKEN_SHA256');

  if (agent.includes(owner)) {
    throw new Error('FILES_AGENT_TOKEN_SHA256 and FILES_OWNER_TOKEN_SHA256 must differ');
  }

  if (new Set(agent).size !== agent.length) {
    throw new Error('FILES_AGENT_TOKEN_SHA256 must not repeat a hash');
  }

  return {
    port: requirePort(env['FILES_PORT'] ?? '8080'),
    dataDir: requireValue(env, 'FILES_DATA_DIR'),
    publicURL: requireOrigin(requireValue(env, 'FILES_PUBLIC_URL')),
    tokenHashes: { agent, owner },
  };
}

function requireHashList(
  env: Readonly<Record<string, string | undefined>>,
  name: string,
): string[] {
  return requireValue(env, name)
    .split(',')
    .map((value) => {
      const hash = findHash(value.trim());

      if (hash === undefined) {
        throw new Error(`${name} must hold SHA-256 digests as 64 hex characters, split by commas`);
      }

      return hash;
    });
}

function requireValue(env: Readonly<Record<string, string | undefined>>, name: string): string {
  const value = env[name]?.trim() ?? '';

  if (value === '') {
    throw new Error(`${name} is not set`);
  }

  return value;
}

function findHash(value: string): string | undefined {
  const hash = value.toLowerCase();

  return /^[\da-f]{64}$/u.test(hash) ? hash : undefined;
}

function requireHash(env: Readonly<Record<string, string | undefined>>, name: string): string {
  const hash = findHash(requireValue(env, name));

  if (hash === undefined) {
    throw new Error(`${name} must be a SHA-256 digest as 64 hex characters`);
  }

  return hash;
}

// one hash, or several separated by commas

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
