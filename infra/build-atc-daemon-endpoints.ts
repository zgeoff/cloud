import type { ATCGatewayInputs } from './atc-gateway.ts';
import type { ATCDaemonEndpoint } from './build-alert-rules.ts';

// the gateway's daemons, for the probe and its alert; none without the gateway
export function buildATCDaemonEndpoints(
  gateway: Pick<ATCGatewayInputs, 'daemons'> | undefined,
): readonly ATCDaemonEndpoint[] | undefined {
  if (gateway === undefined) {
    return undefined;
  }

  return Object.entries(gateway.daemons).map(([name, daemon]) => ({
    name,
    address: daemon.address,
    alertSeverity: daemon.alertSeverity,
  }));
}
