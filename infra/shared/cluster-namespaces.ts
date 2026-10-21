export const clusterNamespaceNames = [
  'atc',
  'default',
  'files',
  'ingress',
  'kube-node-lease',
  'kube-public',
  'kube-system',
  'nixie',
  'nixie-ingress',
  'observability',
  'onepassword',
] as const;

export type ClusterNamespace = (typeof clusterNamespaceNames)[number];

interface ClusterNamespaceEntry {
  readonly owner: 'pulumi' | 'k3s';
  readonly podSecurity: 'baseline' | 'exempt';
  readonly egress: 'deny' | 'open';
}

// exempt from Pod Security: node-exporter in observability needs hostNetwork, nixie's Traefik in
// nixie-ingress a hostPort, and kube-system's local-path helper pods a hostPath
export const clusterNamespaces = {
  atc: { owner: 'pulumi', podSecurity: 'baseline', egress: 'deny' },
  default: { owner: 'k3s', podSecurity: 'baseline', egress: 'deny' },
  files: { owner: 'pulumi', podSecurity: 'baseline', egress: 'deny' },
  ingress: { owner: 'pulumi', podSecurity: 'baseline', egress: 'deny' },
  'kube-node-lease': { owner: 'k3s', podSecurity: 'baseline', egress: 'deny' },
  'kube-public': { owner: 'k3s', podSecurity: 'baseline', egress: 'deny' },
  'kube-system': { owner: 'k3s', podSecurity: 'exempt', egress: 'deny' },
  nixie: { owner: 'pulumi', podSecurity: 'baseline', egress: 'open' },
  'nixie-ingress': { owner: 'pulumi', podSecurity: 'exempt', egress: 'deny' },
  observability: { owner: 'pulumi', podSecurity: 'exempt', egress: 'deny' },
  onepassword: { owner: 'pulumi', podSecurity: 'baseline', egress: 'deny' },
} as const satisfies Record<ClusterNamespace, ClusterNamespaceEntry>;

export type PulumiNamespace = {
  [Name in ClusterNamespace]: (typeof clusterNamespaces)[Name]['owner'] extends 'pulumi'
    ? Name
    : never;
}[ClusterNamespace];
