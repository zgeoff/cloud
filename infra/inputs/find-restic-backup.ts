import type { Environment } from './types.ts';

export interface ResticBackupTarget {
  readonly prefix: string;

  readonly label: string;

  readonly path: string;
}

interface ResticBackupValues {
  readonly repository: string;
  readonly password: string;
  readonly accessKeyID: string;
  readonly secretAccessKey: string;
}

export function findResticBackup(
  env: Environment,
  target: ResticBackupTarget,
): ResticBackupValues | undefined {
  const names = buildVariableNames(target.prefix);

  if (!hasAnyVariable(env, Object.values(names))) {
    return undefined;
  }

  requireEveryVariable(env, Object.values(names), target.label);

  return {
    repository: buildRepository(env, names, target.path),
    password: getValue(env, names.password),
    accessKeyID: getValue(env, names.accessKeyID),
    secretAccessKey: getValue(env, names.secretAccessKey),
  };
}

function hasAnyVariable(env: Environment, variables: readonly string[]): boolean {
  return variables.some((name) => (env[name] ?? '') !== '');
}

function requireEveryVariable(env: Environment, variables: readonly string[], label: string): void {
  const missing = variables.filter((name) => (env[name] ?? '') === '');

  if (missing.length > 0) {
    throw new Error(
      `${label} needs every one of ${variables.join(', ')}; unset: ${missing.join(', ')}`,
    );
  }

  const blank = variables.filter((name) => getValue(env, name).trim() === '');

  if (blank.length > 0) {
    throw new Error(
      `${label} needs a value in every one of ${variables.join(', ')}; only whitespace: ${blank.join(', ')}`,
    );
  }
}

function buildVariableNames(prefix: string) {
  return {
    password: `${prefix}_RESTIC_PASSWORD`,
    accessKeyID: `${prefix}_R2_ACCESS_KEY_ID`,
    secretAccessKey: `${prefix}_R2_SECRET_ACCESS_KEY`,
    endpoint: `${prefix}_R2_ENDPOINT`,
    bucket: `${prefix}_R2_BUCKET`,
  } as const;
}

function buildRepository(
  env: Environment,
  names: ReturnType<typeof buildVariableNames>,
  path: string,
): string {
  const endpoint = getValue(env, names.endpoint);
  const bucket = getValue(env, names.bucket);
  const host = endpoint.slice('https://'.length);

  if (!endpoint.startsWith('https://') || host === '' || host.includes('/')) {
    throw new Error(`${names.endpoint} must be an https:// origin with no path`);
  }

  if (!/^[\da-z][\da-z-]{1,61}[\da-z]$/u.test(bucket)) {
    throw new Error(`${names.bucket} must be a bare bucket name`);
  }

  return `s3:${endpoint}/${bucket}/${path}`;
}

function getValue(env: Environment, name: string): string {
  return env[name] ?? '';
}
