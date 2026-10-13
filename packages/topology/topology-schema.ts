import { z } from 'zod';

const portSchema = z.int().min(1).max(65_535);

// the Onidel VM: its ID, which infra adopts and the snapshot script names, and the static public
// addresses the host sets on eth0
const vmSchema = z.strictObject({ id: z.uuid(), publicIPv4: z.ipv4(), publicIPv6: z.ipv6() });

// a Tailscale ACL tag, as the policy file and `tailscale up --advertise-tags` name it
const tagSchema = z.string().regex(/^tag:[a-z][\da-z-]*$/u);

const tagsSchema = z.strictObject({
  cloud: tagSchema,
  cloudDeploy: tagSchema,
  imp: tagSchema,
  impE2E: tagSchema,
});

// each long-lived node's stable tailnet address
const nodeSchema = z.strictObject({ address: z.ipv4() });

const nodesSchema = z.strictObject({
  geoffcloud: nodeSchema,
  homePC: nodeSchema,
  imp: z.strictObject({ hostname: z.hostname(), address: z.ipv4() }),
});

// directPort is WireGuard's UDP port for direct connections, open on the host and the edge
const tailnetSchema = z.strictObject({
  cidr: z.cidrv4(),
  directPort: portSchema,
  tags: tagsSchema,
  nodes: nodesSchema,
});

// k3s's default ranges (the host passes no --cluster-cidr or --service-cidr), its API port, and
// Grafana's NodePort
const k3sSchema = z.strictObject({
  podCIDR: z.cidrv4(),
  serviceCIDR: z.cidrv4(),
  apiPort: portSchema,
  grafanaNodePort: portSchema,
});

// The shape of constants.json. Each object is strict, so a misspelt or stale key fails the parse
// instead of reading as unset.
export const topologySchema = z.strictObject({
  vm: vmSchema,
  tailnet: tailnetSchema,
  k3s: k3sSchema,

  // docker0 on the host, where imp-host runs
  docker: z.strictObject({ bridgeAddress: z.ipv4(), subnet: z.cidrv4() }),
  atc: z.strictObject({ daemonPort: portSchema, gatewayPort: portSchema }),

  // impd's tailnet HTTPS domain, and its API port on loopback and between impd nodes
  imp: z.strictObject({ domain: z.hostname(), apiPort: portSchema }),

  // the Connect Service's pinned ClusterIP and port, which the host's relay dials
  onePasswordConnect: z.strictObject({ clusterIP: z.ipv4(), port: portSchema }),
  nodeExporter: z.strictObject({ textfileDir: z.string().startsWith('/') }),
});

export type Topology = z.infer<typeof topologySchema>;
