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

// The gateway's registry file, in atc's format: the daemons it dials, by name, and the
// one a call without a daemon goes to.
export function buildATCGatewayRegistry(
  daemons: Readonly<Record<string, RegistryDaemon>>,
  defaultDaemon: string,
): ATCGatewayRegistry {
  return {
    daemons: Object.fromEntries(
      Object.entries(daemons).map(([name, daemon]) => [
        name,
        { address: daemon.address, daemonID: daemon.daemonID },
      ]),
    ),
    defaultDaemon,
  };
}
