import type { Output } from '@pulumi/pulumi';
import type { ATCGatewayOutputs } from './atc-gateway.ts';

// the tunnel ingress for the gateway's public hostname, and the URL the external health
// check probes there
export interface ATCGatewayRoute {
  readonly hostname: string;
  readonly service: Output<string>;
  readonly healthURL: string;
}

interface GatewayOutputs {
  readonly atcGatewayServiceURL: Output<string>;
  readonly atcGatewayRoute: ATCGatewayRoute;
}

// the gateway's in-cluster URL, and its route: the public host the tunnel sends to that
// URL, and the OAuth metadata URL the health check probes, which the gateway serves
// without a token
export function buildATCGatewayRouteOutputs(
  gateway: Pick<ATCGatewayOutputs, 'serviceURL' | 'publicHost'>,
): GatewayOutputs {
  return {
    atcGatewayServiceURL: gateway.serviceURL,
    atcGatewayRoute: {
      hostname: gateway.publicHost,
      service: gateway.serviceURL,
      healthURL: `https://${gateway.publicHost}/.well-known/oauth-protected-resource/mcp`,
    },
  };
}
