import type { ClusterNamespace } from './cluster-namespaces.ts';
import { clusterNamespaces } from './cluster-namespaces.ts';

// warn and audit report a pod that baseline forbids and still admit it
const podSecurityLabels = {
  'pod-security.kubernetes.io/audit': 'baseline',
  'pod-security.kubernetes.io/warn': 'baseline',
};

interface NamespaceMetadata {
  readonly name: ClusterNamespace;
  readonly labels?: Readonly<Record<string, string>>;
}

export function buildNamespaceMetadata(name: ClusterNamespace): NamespaceMetadata {
  return clusterNamespaces[name].podSecurity === 'exempt'
    ? { name }
    : { name, labels: podSecurityLabels };
}
