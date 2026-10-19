import type { ClusterNamespace } from './cluster-namespaces.ts';
import { clusterNamespaces } from './cluster-namespaces.ts';

// The namespaces k3s creates that carry Pod Security labels, which Pulumi patches on: an exempt one
// needs no patch
export function collectK3sLabelledNamespaces(): ClusterNamespace[] {
  return (Object.keys(clusterNamespaces) as ClusterNamespace[]).filter(
    (name) =>
      clusterNamespaces[name].owner === 'k3s' && clusterNamespaces[name].podSecurity !== 'exempt',
  );
}
