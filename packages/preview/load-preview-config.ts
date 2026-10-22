import type { KeyObject } from 'node:crypto';
import { createPrivateKey } from 'node:crypto';
import { join } from 'node:path';
import { z } from 'zod';
import type { GitHubApp } from './build-github-client.ts';
import type { ContractSettings, PreviewSettings, SpendPrices, SpendSettings } from './types.ts';

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
  readonly githubApp: GitHubApp;
  readonly impdToken: string;
  readonly sweepIntervalMs: number;

  // the route listener on the docker bridge, which the model secret's upstream names, and the
  // proxies behind it; null runs the previews without a spend cap
  readonly spend: { readonly listener: Listener; readonly settings: SpendSettings } | null;
}

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

  const readAppKey = async (): Promise<KeyObject> => {
    const pem = await readCredential('github-app-key');

    return parseAppKey(pem);
  };

  return {
    settings: {
      baseURL: requireValue(env, 'PREVIEW_BASE_URL').replace(/\/+$/u, ''),
      repos: parseRepos(requireValue(env, 'PREVIEW_REPOS'), 'PREVIEW_REPOS'),
      slots: requireInteger(env, 'PREVIEW_SLOTS', '1'),
      idleMs: requireInteger(env, 'PREVIEW_IDLE_MINUTES', '30') * 60_000,
      impDomain: requireValue(env, 'PREVIEW_IMP_DOMAIN'),
      impImage: requireValue(env, 'PREVIEW_IMP_IMAGE'),
      impMemoryMib: requireInteger(env, 'PREVIEW_IMP_MEMORY_MIB', '2048'),
      impGitHubSecret: env['PREVIEW_IMP_GITHUB_SECRET'] ?? null,
      impModelSecret: env['PREVIEW_IMP_MODEL_SECRET'] ?? null,
      buildTimeoutMs: requireInteger(env, 'PREVIEW_BUILD_TIMEOUT_SECONDS', '1800') * 1000,
      healthTimeoutMs: requireInteger(env, 'PREVIEW_HEALTH_TIMEOUT_SECONDS', '600') * 1000,
      healthPollMs: 2000,
      contract: parseContractSettings(env),
    },
    linkListener: parseListener(requireValue(env, 'PREVIEW_LINK_LISTEN')),
    webhookListener: parseListener(requireValue(env, 'PREVIEW_WEBHOOK_LISTEN')),
    impdURL: requireValue(env, 'PREVIEW_IMPD_URL').replace(/\/+$/u, ''),
    databasePath: requireValue(env, 'PREVIEW_DATABASE'),
    webhookSecret: await readCredential('webhook-secret'),
    githubApp: {
      clientID: await readCredential('github-app-client-id'),
      privateKey: await readAppKey(),
    },
    impdToken: await readCredential('imp-token'),
    sweepIntervalMs: 60_000,
    spend: parseSpendConfig(env),
  };
}

function requireValue(env: Readonly<Record<string, string | undefined>>, name: string): string {
  const value = env[name];

  if (value === undefined || value === '') {
    throw new Error(`${name} is not set`);
  }

  return value;
}

function parseAppKey(pem: string): KeyObject {
  try {
    return createPrivateKey(pem);
  } catch {
    // OpenSSL's message, such as `PEM routines:OPENSSL_internal:NO_START_LINE`, names no credential
    throw new Error('the credential github-app-key is not a PEM private key');
  }
}

function parseRepos(list: string, name: string): ReadonlySet<string> {
  const repos = list
    .split(',')
    .map((repo) => repo.trim())
    .filter((repo) => repo !== '');

  const invalidRepo = repos.find((repo) => !/^[\w.-]+\/(?:[\w.-]+|\*)$/u.test(repo));

  if (invalidRepo !== undefined) {
    throw new Error(`${name} names ${invalidRepo}, which is not owner/name or owner/*`);
  }

  return new Set(repos);
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

function parseContractSettings(
  env: Readonly<Record<string, string | undefined>>,
): ContractSettings | null {
  const repos = parseRepos(env['PREVIEW_CONTRACT_REPOS'] ?? '', 'PREVIEW_CONTRACT_REPOS');

  if (repos.size === 0) {
    return null;
  }

  return {
    repos,

    // a run without the model secret would only fail
    modelSecret: requireValue(env, 'PREVIEW_CONTRACT_MODEL_SECRET'),
    timeoutMs: requireInteger(env, 'PREVIEW_CONTRACT_TIMEOUT_MINUTES', '10') * 60_000,
  };
}

function parseListener(address: string): Listener {
  const match = /^(?<hostname>.+):(?<port>\d+)$/u.exec(address);
  const hostname = match?.groups?.['hostname'];

  if (hostname === undefined) {
    throw new Error(`${address} is not host:port`);
  }

  return { hostname, port: Number(match?.groups?.['port']) };
}

function parseSpendConfig(
  env: Readonly<Record<string, string | undefined>>,
): PreviewConfig['spend'] {
  const listen = env['PREVIEW_SPEND_LISTEN'] ?? '';

  if (listen === '') {
    return null;
  }

  return {
    listener: parseListener(listen),
    settings: {
      proxyPath: requireValue(env, 'PREVIEW_SPEND_PROXY'),
      directory: requireValue(env, 'PREVIEW_SPEND_DIRECTORY'),
      upstream: requireValue(env, 'PREVIEW_SPEND_UPSTREAM').replace(/\/+$/u, ''),
      model: requireValue(env, 'PREVIEW_SPEND_MODEL'),
      prices: parsePrices(requireValue(env, 'PREVIEW_SPEND_PRICES')),
      limitDollars: requirePositiveNumber(env, 'PREVIEW_SPEND_LIMIT_DOLLARS'),
      idleMs: requireInteger(env, 'PREVIEW_IDLE_MINUTES', '30') * 60_000,
    },
  };
}

const pricesSchema = z.strictObject({
  input: z.number().nonnegative(),
  cache_write: z.number().nonnegative(),
  cache_write_1h: z.number().nonnegative(),
  cached_input: z.number().nonnegative(),
  output: z.number().nonnegative(),
});

function parsePrices(text: string): SpendPrices {
  const parsed = pricesSchema.safeParse(parseJSONOrNull(text));

  if (!parsed.success) {
    throw new Error(
      'PREVIEW_SPEND_PRICES is not a JSON object of input, cache_write, cache_write_1h, cached_input and output prices',
    );
  }

  return parsed.data;
}

function parseJSONOrNull(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

function requirePositiveNumber(
  env: Readonly<Record<string, string | undefined>>,
  name: string,
): number {
  const text = requireValue(env, name);
  const value = Number(text);

  if (!/^\d+(?:\.\d+)?$/u.test(text) || value <= 0) {
    throw new Error(`${name} is ${text}, not a positive number`);
  }

  return value;
}
