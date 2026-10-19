import type { ClusterNamespace } from './cluster-namespaces.ts';
import { clusterNamespaceNames, clusterNamespaces } from './cluster-namespaces.ts';

export function collectK3sLabelledNamespaces(): ClusterNamespace[] {
  return clusterNamespaceNames.filter(
    (name) =>
      clusterNamespaces[name].owner === 'k3s' && clusterNamespaces[name].podSecurity !== 'exempt',
  );
}
