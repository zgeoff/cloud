import type { PepysRouteTable } from '../shared/parse-pepys-route-table.ts';

// A Go regular expression for cloudflared, which matches it anywhere in the decoded path: anchored
// at both ends, so the tunnel carries exactly the routes the table marks public.
export function buildPepysPublicPath(table: PepysRouteTable): string | undefined {
  const routes = table.routes.filter((route) => route.reach === 'public');

  if (routes.length === 0) {
    return undefined;
  }

  return `^(?:${routes.map((route) => escapeRegExp(route.route)).join('|')})$`;
}

function escapeRegExp(text: string): string {
  return text.replaceAll(/[$()*+.?[\\\]^{|}]/gu, String.raw`\$&`);
}
