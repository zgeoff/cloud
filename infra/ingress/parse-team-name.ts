const authDomainSuffix = '.cloudflareaccess.com';

// The Zero Trust team name that cloudflared needs to check an Access token, from the
// organization's auth domain (`<team>.cloudflareaccess.com`). Any other domain fails the preview,
// because cloudflared would fetch the token's signing keys from the wrong place.
export function parseTeamName(authDomain: string): string {
  const teamName = authDomain.endsWith(authDomainSuffix)
    ? authDomain.slice(0, -authDomainSuffix.length)
    : '';

  if (!/^[a-z0-9-]+$/u.test(teamName)) {
    throw new Error(
      `the Zero Trust auth domain ${authDomain} is not <team>${authDomainSuffix}, so cloudflared cannot check Access tokens`,
    );
  }

  return teamName;
}
