// The one daemon the gateway dials today: atc's daemon on geoffcloud.
const atcGatewayDaemonName = 'geoffcloud';

// atc reads each daemon's bearer token from ATC_GATEWAY_TOKEN_<NAME>, the name
// upper-cased with `-` as `_`
export const atcGatewayTokenVariable = `ATC_GATEWAY_TOKEN_${atcGatewayDaemonName.toUpperCase().replaceAll('-', '_')}`;

interface RegistryDaemon {
  // the daemon's tailnet host:port
  readonly address: string;

  // the identity the daemon minted (`atc daemon id`); the gateway refuses a
  // daemon that answers with another
  readonly daemonID: string;
}

interface ATCGatewayRegistry {
  readonly daemons: Readonly<Record<string, RegistryDaemon>>;
  readonly defaultDaemon: string;
}

// The gateway's registry file, in atc's format: the daemons it dials and the one a
// call without a daemon goes to.
export function buildATCGatewayRegistry(daemon: RegistryDaemon): ATCGatewayRegistry {
  return {
    daemons: { [atcGatewayDaemonName]: { address: daemon.address, daemonID: daemon.daemonID } },
    defaultDaemon: atcGatewayDaemonName,
  };
}
