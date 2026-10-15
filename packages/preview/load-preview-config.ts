import { join } from 'node:path';
import type { PreviewSettings } from './types.ts';

interface Listener {
  readonly hostname: string;
  readonly port: number;
}

export interface PreviewConfig {
  readonly settings: PreviewSettings;
  readonly linkListener: Listener;
  readonly webhookListener: Listener;
  readonly impdURL: string;
  readonly databasePath: string;
  readonly webhookSecret: string;
  readonly githubToken: string;
  readonly impdToken: string;
  readonly sweepIntervalMs: number;
}

// The service's configuration, from its environment, and its three secrets, from the files
// systemd's LoadCredential puts in $CREDENTIALS_DIRECTORY: `webhook-secret`, `github-token` and
// `imp-token`. A missing or malformed value throws, so the service never starts half-configured.
export async function loadPreviewConfig(
  env: Readonly<Record<string, string | undefined>>,
  readText: (path: string) => Promise<string>,
): Promise<PreviewConfig> {
  const credentials = requireValue(env, 'CREDENTIALS_DIRECTORY');

  const readCredential = async (name: string): Promise<string> => {
    const text = await readText(join(credentials, name));

    const value = text.trim();

    if (value === '') {
      throw new Error(`the credential ${name} is empty`);
    }

    return value;
  };

  return {
    settings: {
      baseURL: requireValue(env, 'PREVIEW_BASE_URL').replace(/\/+$/u, ''),
      repos: parseRepos(requireValue(env, 'PREVIEW_REPOS')),
      slots: requireInteger(env, 'PREVIEW_SLOTS', '1'),
      idleMs: requireInteger(env, 'PREVIEW_IDLE_MINUTES', '30') * 60_000,
      impDomain: requireValue(env, 'PREVIEW_IMP_DOMAIN'),
      impImage: requireValue(env, 'PREVIEW_IMP_IMAGE'),
      impMemoryMib: requireInteger(env, 'PREVIEW_IMP_MEMORY_MIB', '4096'),
      impGitHubSecret: env['PREVIEW_IMP_GITHUB_SECRET'] ?? null,
      healthTimeoutMs: requireInteger(env, 'PREVIEW_HEALTH_TIMEOUT_SECONDS', '600') * 1000,
      healthPollMs: 2000,
    },
    linkListener: parseListener(requireValue(env, 'PREVIEW_LINK_LISTEN')),
    webhookListener: parseListener(requireValue(env, 'PREVIEW_WEBHOOK_LISTEN')),
    impdURL: requireValue(env, 'PREVIEW_IMPD_URL').replace(/\/+$/u, ''),
    databasePath: requireValue(env, 'PREVIEW_DATABASE'),
    webhookSecret: await readCredential('webhook-secret'),
    githubToken: await readCredential('github-token'),
    impdToken: await readCredential('imp-token'),
    sweepIntervalMs: 60_000,
  };
}

function requireValue(env: Readonly<Record<string, string | undefined>>, name: string): string {
  const value = env[name];

  if (value === undefined || value === '') {
    throw new Error(`${name} is not set`);
  }

  return value;
}

function requireInteger(
  env: Readonly<Record<string, string | undefined>>,
  name: string,
  fallback: string,
): number {
  const text = env[name] ?? fallback;
  const value = Number(text);

  if (!/^\d+$/u.test(text) || value < 1) {
    throw new Error(`${name} is ${text}, not a positive integer`);
  }

  return value;
}

function parseListener(address: string): Listener {
  const match = /^(?<hostname>.+):(?<port>\d+)$/u.exec(address);
  const hostname = match?.groups?.['hostname'];

  if (hostname === undefined) {
    throw new Error(`${address} is not host:port`);
  }

  return { hostname, port: Number(match?.groups?.['port']) };
}

function parseRepos(list: string): ReadonlySet<string> {
  const repos = list
    .split(',')
    .map((repo) => repo.trim())
    .filter((repo) => repo !== '');

  const invalidRepo = repos.find((repo) => !/^[\w.-]+\/(?:[\w.-]+|\*)$/u.test(repo));

  if (invalidRepo !== undefined) {
    throw new Error(`PREVIEW_REPOS names ${invalidRepo}, which is not owner/name or owner/*`);
  }

  return new Set(repos);
}
