import type { Output } from '@pulumi/pulumi';
import { toATCGatewayTokenVariable } from './to-atc-gateway-token-variable.ts';

// The daemon-token Secret's data: each daemon's bearer token under the
// ATC_GATEWAY_TOKEN_<NAME> variable the gateway reads it from, through envFrom
export function buildATCGatewayTokenData(
  tokens: Readonly<Record<string, Output<string>>>,
): Record<string, Output<string>> {
  return Object.fromEntries(
    Object.entries(tokens).map(([name, token]) => [toATCGatewayTokenVariable(name), token]),
  );
}
