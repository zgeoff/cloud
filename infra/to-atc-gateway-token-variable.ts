// atc reads each daemon's bearer token from ATC_GATEWAY_TOKEN_<NAME>, the name
// upper-cased with `-` as `_` (atc's parseGatewayRegistry)
export function toATCGatewayTokenVariable(daemonName: string): string {
  return `ATC_GATEWAY_TOKEN_${daemonName.toUpperCase().replaceAll('-', '_')}`;
}
