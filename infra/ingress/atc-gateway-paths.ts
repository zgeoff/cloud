// From atc's MCP HTTP server's route table.
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
