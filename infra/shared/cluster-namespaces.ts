// Every namespace in the cluster, who creates it, and its Pod Security level (GEO-1246). Exempt:
// observability's node-exporter needs hostNetwork, and kube-system's local-path helper pods mount a
// hostPath for each new volume.
export const clusterNamespaces = {
  atc: { owner: 'pulumi', podSecurity: 'baseline' },
  default: { owner: 'k3s', podSecurity: 'baseline' },
  ingress: { owner: 'pulumi', podSecurity: 'baseline' },
  'kube-node-lease': { owner: 'k3s', podSecurity: 'baseline' },
  'kube-public': { owner: 'k3s', podSecurity: 'baseline' },
  'kube-system': { owner: 'k3s', podSecurity: 'exempt' },
  nixie: { owner: 'pulumi', podSecurity: 'baseline' },
  observability: { owner: 'pulumi', podSecurity: 'exempt' },
  onepassword: { owner: 'pulumi', podSecurity: 'baseline' },
} as const;

export type ClusterNamespace = keyof typeof clusterNamespaces;

// the namespaces Pulumi declares as Namespace resources
export type PulumiNamespace = {
  [Name in ClusterNamespace]: (typeof clusterNamespaces)[Name]['owner'] extends 'pulumi'
    ? Name
    : never;
}[ClusterNamespace];
