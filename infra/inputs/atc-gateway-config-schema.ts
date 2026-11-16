import { isIP } from 'node:net';
import { topology } from '@zgeoff/cloud-topology';
import { z } from 'zod';
import { atcGatewayServiceClients } from '../shared/atc-gateway-service-clients.ts';
import { pinnedImagePattern } from './pinned-image-pattern.ts';

// atc-gateway:2.10.0 holds atc 2.10.0's `atc` binary, published for the fixture
// only; it is not the gateway
const standInDigest = 'sha256:86cd2af8f297cb5143cee19e71b921d6ba0bc3e3a004d6498be7533b34a068be';

const pinnedImageSchema = z
  .string({ error: 'must name an image by tag and digest' })
  .regex(pinnedImagePattern, 'must name an image by tag and digest');

// a lowercase DNS label that atc's registry also takes (^[a-z][a-z0-9-]{0,30}$): a
// letter first, no `-` last, at most 31 characters
const daemonNamePattern = /^[a-z](?:[\da-z-]{0,29}[\da-z])?$/u;

// atc's registry parser takes ports 1–65535
const addressPattern = /^(?:\[[^\]]+\]|[^:[\]]+):(?<port>\d{1,5})$/u;
const addressMessage = `must be the daemon's tailnet host:port, such as ${topology.tailnet.nodes.geoffcloud.address}:${topology.atc.daemonPort}`;

// a daemonID as a daemon mints it: a lowercase UUID
const daemonIDPattern = /^[\da-f]{8}-[\da-f]{4}-[\da-f]{4}-[\da-f]{4}-[\da-f]{12}$/u;

const daemonIDUnsetMessage =
  'is unset: pin the daemon with the output of `atc daemon id` on its host';

const daemonSchema = z.object(
  {
    address: z
      .string({ error: addressMessage })
      .refine((address) => isPort(addressPattern.exec(address)?.groups?.['port']), addressMessage),
    daemonID: z
      .string({ error: daemonIDUnsetMessage })
      .min(1, daemonIDUnsetMessage)
      .regex(daemonIDPattern, 'must be a lowercase UUID, as `atc daemon id` prints it'),

    // A host that sleeps, such as a PC, takes warning.
    alertSeverity: z
      .enum(['critical', 'warning'], {
        error: (issue) => `must be critical or warning, got ${String(issue.input)}`,
      })
      .default('critical'),
  },
  { error: "must be an object with the daemon's address and daemonID" },
);

const daemonsUnsetMessage =
  'is unset or empty: give each daemon as atcGateway.daemons.<name> with its address and daemonID (they replace atcGateway.daemonAddress and daemonID)';

// atc 2.24.0's MAX_REGISTRY_DAEMONS (src/federation/max-registry-daemons.ts): the most
// daemons whose events cursor fits 4096 bytes. Recheck it when the gateway's atc moves.
const maxDaemons = 34;

const defaultDaemonUnsetMessage =
  'is unset: name the daemon a call without one goes to, one of atcGateway.daemons';

const trustedProxyMessage =
  'must be an IP address as the socket reports the proxy, such as 127.0.0.1: atc takes no range or name';

// atc's rule for a service client's name; a record's key schema drops its message, so the names get
// a refine
const serviceClientNamePattern = /^[a-z][\da-z-]{0,31}$/u;

// the first atc release whose gateway takes `secretDigests` in --service-token-file; an older
// gateway refuses the file and exits at start
const secretDigestRelease = [7, 16, 0] as const;

const serviceClientDigestsSchema = z
  .record(z.string(), z.string().regex(/^[\da-f]{64}$/u, 'must be a sha256 digest in hex'))
  .refine(
    (digests) => Object.keys(digests).every((client) => serviceClientNamePattern.test(client)),
    'each client name must be a lowercase name of at most 32 letters, digits and dashes',
  )
  .refine(
    (digests) => Object.keys(digests).every((client) => !isTokenClient(client)),
    `must not name a client that signs in with a token (${atcGatewayServiceClients.join(', ')})`,
  )
  .refine(
    (digests) => new Set(Object.values(digests)).size === Object.keys(digests).length,
    'each service client needs a digest of its own',
  );

export const atcGatewayConfigSchema = z
  .object(
    {
      image: pinnedImageSchema.refine(
        (image) => !image.includes(standInDigest),
        "is the fixture stand-in, not the gateway; wait for atc's release",
      ),
      backupImage: pinnedImageSchema,

      publicURL: z.url({
        protocol: /^https$/u,
        error: 'must be the https:// origin clients reach, such as https://atc.geoff.cloud',
      }),

      // Each name's bearer token comes from ATC_GATEWAY_TOKEN_<NAME>.
      daemons: z
        .record(z.string().regex(daemonNamePattern), daemonSchema, {
          error: (issue) =>
            issue.code === 'invalid_key'
              ? 'is not a daemon name: a daemon name must be a lowercase DNS label of at most 31 characters, starting with a letter'
              : daemonsUnsetMessage,
        })
        .superRefine((daemons, context) => {
          const count = Object.keys(daemons).length;

          if (count === 0) {
            context.addIssue({ code: 'custom', message: daemonsUnsetMessage });
          }

          if (count > maxDaemons) {
            context.addIssue({
              code: 'custom',
              message: `lists ${count} daemons, over atc's limit of ${maxDaemons}: the gateway refuses such a registry and exits at start`,
            });
          }
        }),

      defaultDaemon: z
        .string({ error: defaultDaemonUnsetMessage })
        .min(1, defaultDaemonUnsetMessage),

      // atc's packaging fixes the path; the default is $HOME's state dir.
      stateDir: z.string().optional(),

      // atc matches the socket's peer exactly, so each is one IP. Unset or empty, every forwarded
      // address reads unverified.
      trustForwardedFrom: z
        .array(z.string().refine((address) => isIP(address) !== 0, trustedProxyMessage))
        .optional(),

      // the sha256 digest of each read-only service client's secret, by client name. Each signs in
      // with the OAuth client_credentials grant.
      serviceClientDigests: serviceClientDigestsSchema.optional(),
    },
    { error: 'must be an object' },
  )
  .superRefine((config, context) => {
    if (!Object.hasOwn(config.daemons, config.defaultDaemon)) {
      context.addIssue({
        code: 'custom',
        path: ['defaultDaemon'],
        message: `'${config.defaultDaemon}' is not in atcGateway.daemons (${Object.keys(config.daemons).join(', ')})`,
      });
    }

    if (
      config.serviceClientDigests !== undefined &&
      Object.keys(config.serviceClientDigests).length > 0 &&
      !isSecretDigestImage(config.image)
    ) {
      context.addIssue({
        code: 'custom',
        path: ['serviceClientDigests'],
        message: `needs an image of atc ${secretDigestRelease.join('.')} or later, whose gateway takes secretDigests; the gateway exits at start on an older one`,
      });
    }
  });

function isPort(port: string | undefined): boolean {
  const value = Number(port ?? 0);

  return value >= 1 && value <= 65_535;
}

function isTokenClient(client: string): boolean {
  return atcGatewayServiceClients.some((name) => name === client);
}

// whether a pinned image such as `ghcr.io/zgeoff/atc-gateway:7.17.0@sha256:...` is a release that
// takes secretDigests
function isSecretDigestImage(image: string): boolean {
  const release = /:(?<release>\d+\.\d+\.\d+)@/u.exec(image)?.groups?.['release'];

  if (release === undefined) {
    return false;
  }

  const parts = release.split('.').map(Number);

  for (const [index, floor] of secretDigestRelease.entries()) {
    const part = parts[index] ?? 0;

    if (part !== floor) {
      return part > floor;
    }
  }

  return true;
}
