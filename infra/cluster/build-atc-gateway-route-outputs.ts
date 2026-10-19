import type { Output } from '@pulumi/pulumi';
import type { ATCGatewayOutputs } from './atc-gateway.ts';

export interface ATCGatewayRoute {
  readonly hostname: string;
  readonly service: Output<string>;
  readonly healthURL: string;
}

interface GatewayOutputs {
  readonly atcGatewayServiceURL: Output<string>;
  readonly atcGatewayRoute: ATCGatewayRoute;
}

export function buildATCGatewayRouteOutputs(gateway: ATCGatewayOutputs): GatewayOutputs {
  return {
    atcGatewayServiceURL: gateway.serviceURL,
    atcGatewayRoute: {
      hostname: gateway.publicHost,
      service: gateway.serviceURL,

      // the gateway serves the OAuth metadata URL without a token
      healthURL: `https://${gateway.publicHost}/.well-known/oauth-protected-resource/mcp`,
    },
  };
}
