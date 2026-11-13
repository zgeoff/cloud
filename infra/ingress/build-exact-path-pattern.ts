// a pattern that matches exactly one of the paths, anchored at both ends, because cloudflared
// matches a rule's path anywhere in the decoded request path
export function buildExactPathPattern(paths: readonly string[]): string {
  return `^(?:${paths.map((path) => path.replaceAll(/[$()*+.?[\\\]^{|}]/gu, String.raw`\$&`)).join('|')})$`;
}
