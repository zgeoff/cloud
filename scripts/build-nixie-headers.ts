// The headers of a call to nixie's API: nixie refuses a call without its client header, which a
// cross-site form cannot send, and reads the device session from a bearer token
export function buildNixieHeaders(token: string | null): Record<string, string> {
  return {
    'content-type': 'application/json',
    'x-nixie-client': 'deploy-check',
    ...(token === null ? {} : { authorization: `Bearer ${token}` }),
  };
}
