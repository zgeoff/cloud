// The Connect server's credentials file (1password-credentials.json), from
// op://cloud/onepassword-connect-credentials. A cluster that is managed needs it: a
// missing value would otherwise plan to delete Connect. The error never carries the value.
export function requireOnePasswordConnectCredentials(value: string | undefined): string {
  if (value === undefined || value.trim() === '') {
    throw new Error(
      'cluster is managed, but ONEPASSWORD_CONNECT_CREDENTIALS is empty; run through `op run --env-file=../.env`',
    );
  }

  if (!isJSONObject(value)) {
    throw new Error('ONEPASSWORD_CONNECT_CREDENTIALS is not a JSON object');
  }

  return value;
}

function isJSONObject(value: string): boolean {
  try {
    const parsed: unknown = JSON.parse(value);

    return typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed);
  } catch {
    return false;
  }
}
