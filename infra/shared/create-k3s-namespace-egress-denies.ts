import type { Provider } from '@pulumi/kubernetes';
import type { NetworkPolicy } from '@pulumi/kubernetes/networking/v1';
import { clusterNamespaces } from './cluster-namespaces.ts';
import { collectEgressDenyNamespaces } from './collect-egress-deny-namespaces.ts';
import { createEgressDeny } from './create-egress-deny.ts';

// k3s creates these namespaces, so each deny names its namespace as plain text
export function createK3sNamespaceEgressDenies(cluster: Provider): NetworkPolicy[] {
  return collectEgressDenyNamespaces()
    .filter((name) => clusterNamespaces[name].owner === 'k3s')
    .map((name) => createEgressDeny(name, name, cluster));
}
