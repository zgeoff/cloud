// From the route table of the boxxy server's public door, in @boxxy/auth-oauth. It has no alias at
// `/`, unlike atc's gateway.
export const boxxyDoorPaths = {
  browser: ['/oauth2/authorize', '/login', '/enroll', '/consent', '/error'],
  machine: [
    '/mcp',
    '/oauth2/token',
    '/oauth2/revoke',
    '/.well-known/oauth-authorization-server',
    '/.well-known/oauth-protected-resource',
    '/.well-known/oauth-protected-resource/mcp',
  ],
} as const;
