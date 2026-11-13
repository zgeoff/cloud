// From the route table of the pepys API's OAuth server. The server takes no dynamic client
// registration, so it serves no register path.
export const pepysAPIPaths = {
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
