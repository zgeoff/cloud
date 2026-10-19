export function buildNixieHeaders(token: string | null): Record<string, string> {
  return {
    'content-type': 'application/json',

    // nixie refuses a call without its client header, which a cross-site form cannot send
    'x-nixie-client': 'deploy-check',
    ...(token === null ? {} : { authorization: `Bearer ${token}` }),
  };
}
