// The Cloudflare account every Cloudflare resource belongs to, from CLOUDFLARE_ACCOUNT_ID.
// Unset, it throws before any resource registers.
export function requireCloudflareAccountID(accountID: string | undefined): string {
  if (accountID === undefined) {
    throw new Error('CLOUDFLARE_ACCOUNT_ID is unset; run through `op run --env-file=../.env`');
  }

  return accountID;
}
