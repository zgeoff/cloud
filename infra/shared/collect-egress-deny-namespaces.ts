import type { ClusterNamespace } from './cluster-namespaces.ts';
import { clusterNamespaceNames, clusterNamespaces } from './cluster-namespaces.ts';

export function collectEgressDenyNamespaces(): ClusterNamespace[] {
  return clusterNamespaceNames.filter((name) => clusterNamespaces[name].egress === 'deny');
}
