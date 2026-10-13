import type { ATCDaemonEndpoint, ATCGatewayConfig } from './inputs/types.ts';

// the gateway's daemons, for the probe and its alert; none without the gateway
export function buildATCDaemonEndpoints(
  config: Pick<ATCGatewayConfig, 'daemons'> | undefined,
): readonly ATCDaemonEndpoint[] | undefined {
  if (config === undefined) {
    return undefined;
  }

  return Object.entries(config.daemons).map(([name, daemon]) => ({
    name,
    address: daemon.address,
    alertSeverity: daemon.alertSeverity,
  }));
}
