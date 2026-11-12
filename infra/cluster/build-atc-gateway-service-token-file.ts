// the file name in the Secret and in the emptyDir the gateway reads it from
export const atcGatewayServiceTokenFile = 'service-tokens.json';

// what a service client may call: the boxxy server reads sessions, spawns them, messages them and
// kills them
const boxxyScopes = ['read', 'spawn', 'message', 'kill'];

interface ServiceTokenFileInputs {
  // the gateway's `--public-url`
  readonly publicURL: string;

  // the bearer token of each service client, by client name
  readonly tokens: Readonly<Record<string, string>>;
}

// The JSON file that `atc-gateway --service-token-file` reads (atc's docs/guides/gateway.md). The
// gateway exits at start when `resource` differs from the resource it serves, which is the public
// URL's origin and `/mcp`.
export function buildATCGatewayServiceTokenFile(inputs: ServiceTokenFileInputs): string {
  return JSON.stringify(
    {
      resource: `${new URL(inputs.publicURL).origin}/mcp`,
      clients: Object.fromEntries(
        Object.entries(inputs.tokens).map(([name, token]) => [
          name,
          { scopes: boxxyScopes, tokens: [token] },
        ]),
      ),
    },
    null,
    2,
  );
}
