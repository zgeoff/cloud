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

// The gateway's typed fleet API, which a program such as nixie calls at `/rpc/<procedure path>`,
// such as `/rpc/session/list`, with a bearer that the gateway checks as it does at `/mcp`. Each
// segment holds only letters, digits, `_` and `-`, so no dot segment reaches past `/rpc`.
export const atcGatewayRPCPathPattern = '^/rpc(?:/[A-Za-z0-9_-]+)+$';
