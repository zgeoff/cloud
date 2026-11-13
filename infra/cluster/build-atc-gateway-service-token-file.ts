import {
  atcGatewayServiceClientScopes,
  atcGatewayServiceClients,
} from '../shared/atc-gateway-service-clients.ts';
import type { ATCGatewayServiceClient } from '../shared/atc-gateway-service-clients.ts';

// the file name in the Secret and in the emptyDir the gateway reads it from
export const atcGatewayServiceTokenFile = 'service-tokens.json';

interface ServiceTokenFileInputs {
  // the gateway's `--public-url`
  readonly publicURL: string;

  // the bearer token of each service client, by client name
  readonly tokens: Readonly<Partial<Record<ATCGatewayServiceClient, string>>>;
}

// The JSON file that `atc-gateway --service-token-file` reads (atc's docs/guides/gateway.md). The
// gateway exits at start when `resource` differs from the resource it serves, which is the public
// URL's origin and `/mcp`.
export function buildATCGatewayServiceTokenFile(inputs: ServiceTokenFileInputs): string {
  return JSON.stringify(
    {
      resource: `${new URL(inputs.publicURL).origin}/mcp`,
      clients: Object.fromEntries(
        atcGatewayServiceClients.flatMap((name) => {
          const token = inputs.tokens[name];

          return token === undefined
            ? []
            : [[name, { scopes: atcGatewayServiceClientScopes[name], tokens: [token] }]];
        }),
      ),
    },
    null,
    2,
  );
}
