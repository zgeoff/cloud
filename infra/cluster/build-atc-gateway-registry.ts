interface RegistryDaemon {
  readonly address: string;

  // minted by `atc daemon id`; the gateway refuses a daemon that answers with another
  readonly daemonID: string;
}

interface ATCGatewayRegistry {
  readonly daemons: Readonly<Record<string, RegistryDaemon>>;
  readonly defaultDaemon: string;
}

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
