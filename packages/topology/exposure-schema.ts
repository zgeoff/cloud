import { z } from 'zod';

// public: from the internet. tailnet: over the tailnet only, shut on the public interface. host:
// on one of the host's own interfaces, for its pods or containers. reserved: a name held for a
// later route. closed: deliberately not exposed.
const scopeSchema = z.enum(['public', 'tailnet', 'host', 'reserved', 'closed']);

// what every entry records: its name, how far it reaches, and why, with the ticket that owns it
const entryFields = {
  name: z.string().regex(/^[a-z][\da-z-]*$/u),
  scope: scopeSchema,
  reason: z.string().min(1),
  ticket: z
    .string()
    .regex(/^GEO-\d+$/u)
    .optional(),
};

// A port the host's firewall opens or keeps shut. interface names the one interface a host-scope
// port opens on, edge is the description of a public port's rule at Onidel's edge firewall, and
// admission marks a port that inet cloud_host narrows to one path.
const hostPortSchema = z.strictObject({
  ...entryFields,
  kind: z.literal('host-port'),
  protocol: z.enum(['tcp', 'udp', 'icmp']),
  port: z.int().min(1).max(65_535).optional(),
  interface: z.string().min(1).optional(),
  edge: z.string().min(1).max(255).optional(),
  admission: z.literal(true).optional(),
});

// a hostname the Cloudflare tunnel serves, or holds free for a later route
const tunnelHostnameSchema = z.strictObject({
  ...entryFields,
  kind: z.literal('tunnel-hostname'),
  hostname: z.hostname(),
});

// a node attribute the tailnet policy grants, such as funnel
const tailnetCapabilitySchema = z.strictObject({
  ...entryFields,
  kind: z.literal('tailnet-capability'),
  attr: z.string().min(1),
});

// a Worker's own workers.dev URL
const workerURLSchema = z.strictObject({
  ...entryFields,
  kind: z.literal('worker-url'),
  script: z.string().min(1),
});

const entrySchema = z.discriminatedUnion('kind', [
  hostPortSchema,
  tunnelHostnameSchema,
  tailnetCapabilitySchema,
  workerURLSchema,
]);

// The shape of exposure.json: every public route and port, and each port the host keeps to the
// tailnet or to itself. The rules that span fields run over the whole list, so each issue's path
// names the entry and the field at fault.
export const exposureSchema = z
  .strictObject({ entries: z.array(entrySchema).readonly() })
  .superRefine(checkEntries);

export type Exposure = z.infer<typeof exposureSchema>;

export type ExposureEntry = Exposure['entries'][number];

type HostPort = z.infer<typeof hostPortSchema>;

interface HostPortIssue {
  readonly field: keyof HostPort;
  readonly message: string;
}

function collectHostPortIssues(entry: HostPort): readonly HostPortIssue[] {
  return [
    ...(entry.protocol === 'icmp' && entry.port !== undefined
      ? [{ field: 'port' as const, message: 'an icmp entry has no port' }]
      : []),
    ...(entry.protocol !== 'icmp' && entry.port === undefined
      ? [{ field: 'port' as const, message: `a ${entry.protocol} entry needs a port` }]
      : []),
    ...(entry.scope === 'host' && entry.interface === undefined
      ? [{ field: 'interface' as const, message: 'a host-scope entry needs an interface' }]
      : []),
    ...(entry.scope !== 'host' && entry.interface !== undefined
      ? [{ field: 'interface' as const, message: 'only a host-scope entry names an interface' }]
      : []),
    ...(entry.scope === 'public' && entry.edge === undefined
      ? [{ field: 'edge' as const, message: 'a public entry needs its edge rule description' }]
      : []),
    ...(entry.scope !== 'public' && entry.edge !== undefined
      ? [{ field: 'edge' as const, message: 'only a public entry has an edge rule' }]
      : []),
    ...(entry.admission === true && entry.scope !== 'host'
      ? [{ field: 'admission' as const, message: 'only a host-scope entry has an admission' }]
      : []),
    ...(entry.scope === 'reserved' || entry.scope === 'closed'
      ? [{ field: 'scope' as const, message: `a host port is never ${entry.scope}` }]
      : []),
  ];
}

// adds an issue for each entry whose name another entry holds, and for each host port whose fields
// disagree with each other
// oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- zod owns the context
function checkEntries(exposure: Exposure, context: z.RefinementCtx): void {
  const names = exposure.entries.map((entry) => entry.name);

  for (const [index, entry] of exposure.entries.entries()) {
    if (names.indexOf(entry.name) !== index) {
      context.addIssue({
        code: 'custom',
        path: ['entries', index, 'name'],
        message: `${entry.name} names another entry`,
      });
    }

    if (entry.kind === 'host-port') {
      for (const issue of collectHostPortIssues(entry)) {
        context.addIssue({
          code: 'custom',
          path: ['entries', index, issue.field],
          message: issue.message,
        });
      }
    }
  }
}
