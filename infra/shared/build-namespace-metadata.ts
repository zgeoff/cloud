import type { ClusterNamespace } from './cluster-namespaces.ts';
import { clusterNamespaces } from './cluster-namespaces.ts';

// enforce refuses a pod that baseline forbids, such as one on the host's network, which no
// NetworkPolicy covers; warn and audit report it too
const podSecurityLabels = {
  'pod-security.kubernetes.io/audit': 'baseline',
  'pod-security.kubernetes.io/enforce': 'baseline',
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
