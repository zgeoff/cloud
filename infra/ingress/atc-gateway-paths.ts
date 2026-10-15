// The atc gateway's public routes by caller, from atc's MCP HTTP server's route table: the owner's
// browser pages behind Access, the MCP clients' machine routes without it. The tunnel answers any
// other path with a 404 (public-ingress.md in docs/architecture/network).
export const atcGatewayPaths = {
  browser: ['/oauth2/authorize', '/login', '/enroll', '/consent', '/error'],
  machine: [
    '/',
    '/mcp',
    '/oauth2/token',
    '/oauth2/revoke',
    '/.well-known/oauth-authorization-server',
    '/.well-known/oauth-protected-resource',
    '/.well-known/oauth-protected-resource/mcp',
  ],
} as const;
