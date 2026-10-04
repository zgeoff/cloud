import type { ATCDaemonAlertSeverity } from './build-alert-rules.ts';
import { toATCGatewayTokenVariable } from './to-atc-gateway-token-variable.ts';

// one daemon's stack config fields; see ATCGatewayConfig
interface DaemonConfigFields {
  readonly address?: string;
  readonly daemonID?: string;
  readonly alertSeverity?: string;
}

// the stack config fields this check reads; see ATCGatewayConfig
interface GatewayConfigFields {
  readonly image: string;
  readonly daemons?: Readonly<Record<string, DaemonConfigFields | undefined>>;
  readonly defaultDaemon?: string;
}

interface CheckedDaemon {
  readonly address: string;
  readonly daemonID: string;
  readonly alertSeverity: ATCDaemonAlertSeverity;
  readonly token: string;
}

interface CheckedGatewayInputs {
  readonly daemons: Readonly<Record<string, CheckedDaemon>>;
  readonly defaultDaemon: string;
}

// Throws, naming the fix, unless the gateway can deploy: a real gateway image, and for
// each daemon a name atc takes, its pinned daemonID and address, and its bearer token,
// with defaultDaemon among them. Each check matches what atc's gateway refuses at
// start, so a mistake fails the preview instead of the pod.
export function requireATCGatewayInputs(
  config: GatewayConfigFields,
  env: Readonly<Record<string, string | undefined>>,
): CheckedGatewayInputs {
  requireRealGateway(config.image);

  const daemons = requireDaemons(config.daemons, env);

  return { daemons, defaultDaemon: requireDefaultDaemon(config.defaultDaemon, daemons) };
}

// atc-gateway:2.10.0 holds atc 2.10.0's `atc` binary, published for the fixture
// only; it is not the gateway
const standInDigest = 'sha256:86cd2af8f297cb5143cee19e71b921d6ba0bc3e3a004d6498be7533b34a068be';

function requireRealGateway(image: string): void {
  if (image.includes(standInDigest) || image.endsWith('atc-gateway:2.10.0')) {
    throw new Error(`${image} is the fixture stand-in, not the gateway; wait for atc's release`);
  }
}

// atc 2.24.0's MAX_REGISTRY_DAEMONS (src/federation/max-registry-daemons.ts): the most
// daemons whose events cursor fits 4096 bytes. Recheck it when the gateway's atc moves.
const maxDaemons = 34;

function requireDaemons(
  daemons: GatewayConfigFields['daemons'],
  env: Readonly<Record<string, string | undefined>>,
): Readonly<Record<string, CheckedDaemon>> {
  const entries = Object.entries(daemons ?? {});

  if (entries.length === 0) {
    throw new Error(
      'atcGateway.daemons is unset or empty: give each daemon as atcGateway.daemons.<name> with its address and daemonID (they replace atcGateway.daemonAddress and daemonID)',
    );
  }

  if (entries.length > maxDaemons) {
    throw new Error(
      `atcGateway.daemons lists ${entries.length} daemons, over atc's limit of ${maxDaemons}: the gateway refuses such a registry and exits at start`,
    );
  }

  return Object.fromEntries(
    entries.map(([name, daemon]) => [name, requireDaemon(name, daemon, env)]),
  );
}

// a lowercase DNS label that atc's registry also takes (^[a-z][a-z0-9-]{0,30}$): a
// letter first, no `-` last, at most 31 characters
const daemonNamePattern = /^[a-z](?:[\da-z-]{0,29}[\da-z])?$/u;

function requireDaemon(
  name: string,
  daemon: DaemonConfigFields | undefined,
  env: Readonly<Record<string, string | undefined>>,
): CheckedDaemon {
  if (!daemonNamePattern.test(name)) {
    throw new Error(
      `atcGateway.daemons.${name}: a daemon name must be a lowercase DNS label of at most 31 characters, starting with a letter`,
    );
  }

  const field = `atcGateway.daemons.${name}`;

  return {
    address: requireDaemonAddress(field, daemon?.address),
    daemonID: requireDaemonID(field, daemon?.daemonID),
    alertSeverity: requireAlertSeverity(field, daemon?.alertSeverity),
    token: requireToken(toATCGatewayTokenVariable(name), env),
  };
}

// `<host>:<port>`, with an IPv6 host in brackets
const addressPattern = /^(?:\[[^\]]+\]|[^:[\]]+):(?<port>\d{1,5})$/u;

function requireDaemonAddress(field: string, address: string | undefined): string {
  const port = Number(addressPattern.exec(address ?? '')?.groups?.['port'] ?? 0);

  // atc's registry parser takes ports 1–65535
  if (address === undefined || port < 1 || port > 65_535) {
    throw new Error(
      `${field}.address must be the daemon's tailnet host:port, such as 100.69.47.33:8415`,
    );
  }

  return address;
}

// a daemonID as a daemon mints it: a lowercase UUID
const daemonIDPattern = /^[\da-f]{8}-[\da-f]{4}-[\da-f]{4}-[\da-f]{4}-[\da-f]{12}$/u;

function requireDaemonID(field: string, daemonID: string | undefined): string {
  if (daemonID === undefined || daemonID === '') {
    throw new Error(
      `${field}.daemonID is unset: pin the daemon with the output of \`atc daemon id\` on its host`,
    );
  }

  if (!daemonIDPattern.test(daemonID)) {
    throw new Error(`${field}.daemonID must be a lowercase UUID, as \`atc daemon id\` prints it`);
  }

  return daemonID;
}

function requireAlertSeverity(field: string, severity: string | undefined): ATCDaemonAlertSeverity {
  if (severity === undefined) {
    return 'critical';
  }

  if (severity !== 'critical' && severity !== 'warning') {
    throw new Error(`${field}.alertSeverity must be critical or warning, got ${severity}`);
  }

  return severity;
}

// atc's daemon takes a token of at least 32 bytes
const minTokenBytes = 32;

function requireToken(variable: string, env: Readonly<Record<string, string | undefined>>): string {
  const token = env[variable];

  if (token === undefined || token === '') {
    throw new Error(`${variable} is empty: .env must reference the daemon's token`);
  }

  if (/\s/u.test(token)) {
    throw new Error(`${variable} must be the one token, with no whitespace`);
  }

  if (Buffer.byteLength(token) < minTokenBytes) {
    throw new Error(`${variable} is shorter than ${minTokenBytes} bytes`);
  }

  return token;
}

function requireDefaultDaemon(
  defaultDaemon: string | undefined,
  daemons: Readonly<Record<string, CheckedDaemon>>,
): string {
  const names = Object.keys(daemons).join(', ');

  if (defaultDaemon === undefined || defaultDaemon === '') {
    throw new Error(
      `atcGateway.defaultDaemon is unset: name the daemon a call without one goes to, one of ${names}`,
    );
  }

  if (!Object.hasOwn(daemons, defaultDaemon)) {
    throw new Error(
      `atcGateway.defaultDaemon '${defaultDaemon}' is not in atcGateway.daemons (${names})`,
    );
  }

  return defaultDaemon;
}
