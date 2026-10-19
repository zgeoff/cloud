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
}

// Every namespace in the cluster, who creates it, and its Pod Security level (GEO-1246). Exempt:
// node-exporter in observability needs hostNetwork, nixie's Traefik in nixie-ingress a hostPort,
// and kube-system's local-path helper pods a hostPath.
export const clusterNamespaces = {
  atc: { owner: 'pulumi', podSecurity: 'baseline' },
  default: { owner: 'k3s', podSecurity: 'baseline' },
  files: { owner: 'pulumi', podSecurity: 'baseline' },
  ingress: { owner: 'pulumi', podSecurity: 'baseline' },
  'kube-node-lease': { owner: 'k3s', podSecurity: 'baseline' },
  'kube-public': { owner: 'k3s', podSecurity: 'baseline' },
  'kube-system': { owner: 'k3s', podSecurity: 'exempt' },
  nixie: { owner: 'pulumi', podSecurity: 'baseline' },
  'nixie-ingress': { owner: 'pulumi', podSecurity: 'exempt' },
  observability: { owner: 'pulumi', podSecurity: 'exempt' },
  onepassword: { owner: 'pulumi', podSecurity: 'baseline' },
} as const satisfies Record<ClusterNamespace, ClusterNamespaceEntry>;

// the namespaces Pulumi declares as Namespace resources
export type PulumiNamespace = {
  [Name in ClusterNamespace]: (typeof clusterNamespaces)[Name]['owner'] extends 'pulumi'
    ? Name
    : never;
}[ClusterNamespace];
