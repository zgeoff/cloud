import type { ClusterNamespace } from './cluster-namespaces.ts';
import { clusterNamespaces } from './cluster-namespaces.ts';

// warn and audit report a pod that baseline forbids and still admit it; enforce follows after a
// clean window (GEO-1246)
const podSecurityLabels = {
  'pod-security.kubernetes.io/audit': 'baseline',
  'pod-security.kubernetes.io/warn': 'baseline',
};

interface NamespaceMetadata {
  readonly name: ClusterNamespace;
  readonly labels?: Readonly<Record<string, string>>;
}

// A namespace's name and its Pod Security labels, which an exempt namespace goes without
export function buildNamespaceMetadata(name: ClusterNamespace): NamespaceMetadata {
  return clusterNamespaces[name].podSecurity === 'exempt'
    ? { name }
    : { name, labels: podSecurityLabels };
}
