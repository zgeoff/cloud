const authDomainSuffix = '.cloudflareaccess.com';

export function parseTeamName(authDomain: string): string {
  const teamName = authDomain.endsWith(authDomainSuffix)
    ? authDomain.slice(0, -authDomainSuffix.length)
    : '';

  // for any other domain, cloudflared would fetch the token's signing keys from the wrong place
  if (!/^[a-z0-9-]+$/u.test(teamName)) {
    throw new Error(
      `the Zero Trust auth domain ${authDomain} is not <team>${authDomainSuffix}, so cloudflared cannot check Access tokens`,
    );
  }

  return teamName;
}
