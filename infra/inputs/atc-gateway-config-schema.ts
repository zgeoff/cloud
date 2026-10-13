import { z } from 'zod';
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

// `<host>:<port>`, with an IPv6 host in brackets; atc's registry parser takes ports 1–65535
const addressPattern = /^(?:\[[^\]]+\]|[^:[\]]+):(?<port>\d{1,5})$/u;
const addressMessage = "must be the daemon's tailnet host:port, such as 100.69.47.33:8415";

// a daemonID as a daemon mints it: a lowercase UUID
const daemonIDPattern = /^[\da-f]{8}-[\da-f]{4}-[\da-f]{4}-[\da-f]{4}-[\da-f]{12}$/u;

const daemonIDUnsetMessage =
  'is unset: pin the daemon with the output of `atc daemon id` on its host';

// one daemon the gateway dials: its tailnet host:port and the daemonID `atc daemon id`
// prints there. Both are required; the deploy refuses without them.
const daemonSchema = z.object(
  {
    address: z
      .string({ error: addressMessage })
      .refine((address) => isPort(addressPattern.exec(address)?.groups?.['port']), addressMessage),
    daemonID: z
      .string({ error: daemonIDUnsetMessage })
      .min(1, daemonIDUnsetMessage)
      .regex(daemonIDPattern, 'must be a lowercase UUID, as `atc daemon id` prints it'),

    // ATCDaemonUnreachable's severity for this daemon. A host that sleeps, such as a PC, takes
    // warning.
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

// The atcGateway stack config; setting it approves the deploy. Each check matches what atc's
// gateway refuses at start, so a mistake fails the preview instead of the pod. Values pass
// through unchanged: only an unset alertSeverity takes its default.
export const atcGatewayConfigSchema = z
  .object(
    {
      // a digest-pinned image built from deploy/atc-gateway, and its backup image
      image: pinnedImageSchema.refine(
        (image) => !image.includes(standInDigest),
        "is the fixture stand-in, not the gateway; wait for atc's release",
      ),
      backupImage: pinnedImageSchema,

      // the origin clients reach, and the OAuth issuer
      publicURL: z.url({
        protocol: /^https$/u,
        error: 'must be the https:// origin clients reach, such as https://atc.geoff.cloud',
      }),

      // the daemons the gateway dials, by name. Each name's bearer token comes from
      // ATC_GATEWAY_TOKEN_<NAME>.
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

      // the daemon a call without one goes to
      defaultDaemon: z
        .string({ error: defaultDaemonUnsetMessage })
        .min(1, defaultDaemonUnsetMessage),

      // where the state volume mounts and --state-dir points: gateway.db and
      // mcp-auth.db. atc's packaging fixes the path; the default is $HOME's state dir.
      stateDir: z.string().optional(),
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
  });

function isPort(port: string | undefined): boolean {
  const value = Number(port ?? 0);

  return value >= 1 && value <= 65_535;
}
