interface GatewayBackupValues {
  readonly repository: string;
  readonly password: string;
  readonly accessKeyID: string;
  readonly secretAccessKey: string;
}

// The gateway backup's inputs from .env, or undefined when none is set (no backup
// CronJob). Throws when only some are set, so a missing reference fails the preview
// instead of silently dropping the backup, and when one holds only whitespace. The
// restic repository is built from the R2 item's endpoint and bucket:
// s3:<endpoint>/<bucket>/atc-gateway.
export function findATCGatewayBackup(
  env: Readonly<Record<string, string | undefined>>,
): GatewayBackupValues | undefined {
  const missing = backupVariables.filter((name) => (env[name] ?? '') === '');

  if (missing.length === backupVariables.length) {
    return undefined;
  }

  if (missing.length > 0) {
    throw new Error(
      `the atc gateway's backup needs every one of ${backupVariables.join(', ')}; unset: ${missing.join(', ')}`,
    );
  }

  const blank = backupVariables.filter((name) => getValue(env, name).trim() === '');

  if (blank.length > 0) {
    throw new Error(
      `the atc gateway's backup needs a value in every one of ${backupVariables.join(', ')}; only whitespace: ${blank.join(', ')}`,
    );
  }

  return {
    repository: buildRepository(
      getValue(env, 'ATC_GATEWAY_R2_ENDPOINT'),
      getValue(env, 'ATC_GATEWAY_R2_BUCKET'),
    ),
    password: getValue(env, 'ATC_GATEWAY_RESTIC_PASSWORD'),
    accessKeyID: getValue(env, 'ATC_GATEWAY_R2_ACCESS_KEY_ID'),
    secretAccessKey: getValue(env, 'ATC_GATEWAY_R2_SECRET_ACCESS_KEY'),
  };
}

const backupVariables = [
  'ATC_GATEWAY_RESTIC_PASSWORD',
  'ATC_GATEWAY_R2_ACCESS_KEY_ID',
  'ATC_GATEWAY_R2_SECRET_ACCESS_KEY',
  'ATC_GATEWAY_R2_ENDPOINT',
  'ATC_GATEWAY_R2_BUCKET',
] as const;

type BackupVariable = (typeof backupVariables)[number];

function buildRepository(endpoint: string, bucket: string): string {
  const host = endpoint.slice('https://'.length);

  if (!endpoint.startsWith('https://') || host === '' || host.includes('/')) {
    throw new Error('ATC_GATEWAY_R2_ENDPOINT must be an https:// origin with no path');
  }

  if (!/^[\da-z][\da-z-]{1,61}[\da-z]$/u.test(bucket)) {
    throw new Error('ATC_GATEWAY_R2_BUCKET must be a bare bucket name');
  }

  return `s3:${endpoint}/${bucket}/atc-gateway`;
}

// every variable is set by the time this runs
function getValue(env: Readonly<Record<string, string | undefined>>, name: BackupVariable): string {
  return env[name] ?? '';
}
