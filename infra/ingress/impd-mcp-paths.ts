// impd's public listener answers only these paths: its MCP endpoint, its OAuth server's endpoints
// and sign-in pages, and its discovery documents. The tunnel passes exactly these, so a route that
// impd adds later reaches nothing until it joins the list.
export const impdMCPPaths = [
  '/mcp',
  '/.well-known/oauth-authorization-server',
  '/.well-known/oauth-protected-resource',
  '/.well-known/oauth-protected-resource/mcp',
  '/oauth2/authorize',
  '/oauth2/token',
  '/oauth2/revoke',
  '/login',
  '/enroll',
  '/consent',
  '/error',
] as const;
