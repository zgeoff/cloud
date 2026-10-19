export function toATCGatewayTokenVariable(daemonName: string): string {
  // atc reads each daemon's bearer token from ATC_GATEWAY_TOKEN_<NAME>, the name upper-cased with
  // `-` as `_` (atc's parseGatewayRegistry)
  return `ATC_GATEWAY_TOKEN_${daemonName.toUpperCase().replaceAll('-', '_')}`;
}
