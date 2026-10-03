import { atcGatewayTokenVariable } from './build-atc-gateway-registry.ts';

// the stack config fields this check reads; see ATCGatewayConfig
interface GatewayConfigFields {
  readonly image: string;
  readonly daemonID?: string;
  readonly daemonAddress?: string;
}

interface CheckedGatewayInputs {
  readonly daemonID: string;
  readonly daemonAddress: string;
  readonly token: string;
}

// Throws, naming the fix, unless the gateway can deploy: a real gateway image, the
// daemon's pinned daemonID and address, and its bearer token. Each check matches
// what atc's gateway refuses at start, so a mistake fails the preview instead of
// the pod.
export function requireATCGatewayInputs(
  config: GatewayConfigFields,
  env: Readonly<Record<string, string | undefined>>,
): CheckedGatewayInputs {
  requireRealGateway(config.image);

  return {
    daemonID: requireDaemonID(config.daemonID),
    daemonAddress: requireDaemonAddress(config.daemonAddress),
    token: requireToken(env[atcGatewayTokenVariable]),
  };
}

// atc-gateway:2.10.0 holds atc 2.10.0's `atc` binary, published for the fixture
// only; it is not the gateway
const standInDigest = 'sha256:86cd2af8f297cb5143cee19e71b921d6ba0bc3e3a004d6498be7533b34a068be';

function requireRealGateway(image: string): void {
  if (image.includes(standInDigest) || image.endsWith('atc-gateway:2.10.0')) {
    throw new Error(`${image} is the fixture stand-in, not the gateway; wait for atc's release`);
  }
}

// a daemonID as a daemon mints it: a lowercase UUID
const daemonIDPattern = /^[\da-f]{8}-[\da-f]{4}-[\da-f]{4}-[\da-f]{4}-[\da-f]{12}$/u;

function requireDaemonID(daemonID: string | undefined): string {
  if (daemonID === undefined || daemonID === '') {
    throw new Error(
      'atcGateway.daemonID is unset: pin the daemon with the output of `atc daemon id` on geoffcloud',
    );
  }

  if (!daemonIDPattern.test(daemonID)) {
    throw new Error('atcGateway.daemonID must be a lowercase UUID, as `atc daemon id` prints it');
  }

  return daemonID;
}

// `<host>:<port>`, with an IPv6 host in brackets
const addressPattern = /^(?:\[[^\]]+\]|[^:[\]]+):(?<port>\d{1,5})$/u;

function requireDaemonAddress(address: string | undefined): string {
  const port = Number(addressPattern.exec(address ?? '')?.groups?.['port'] ?? 0);

  // atc's registry parser takes ports 1–65535
  if (address === undefined || port < 1 || port > 65_535) {
    throw new Error(
      "atcGateway.daemonAddress must be the daemon's tailnet host:port, such as 100.69.47.33:8415",
    );
  }

  return address;
}

// atc's daemon takes a token of at least 32 bytes
const minTokenBytes = 32;

function requireToken(token: string | undefined): string {
  if (token === undefined || token === '') {
    throw new Error(`${atcGatewayTokenVariable} is empty: .env must reference the daemon's token`);
  }

  if (/\s/u.test(token)) {
    throw new Error(`${atcGatewayTokenVariable} must be the one token, with no whitespace`);
  }

  if (Buffer.byteLength(token) < minTokenBytes) {
    throw new Error(`${atcGatewayTokenVariable} is shorter than ${minTokenBytes} bytes`);
  }

  return token;
}
