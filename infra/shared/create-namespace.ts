import type { Provider } from '@pulumi/kubernetes';
import { Namespace } from '@pulumi/kubernetes/core/v1';
import { buildNamespaceMetadata } from './build-namespace-metadata.ts';
import type { PulumiNamespace } from './cluster-namespaces.ts';
import { clusterNamespaces } from './cluster-namespaces.ts';
import { createEgressDeny } from './create-egress-deny.ts';

// the namespace, with its egress deny when the namespace has one
export function createNamespace(name: PulumiNamespace, cluster: Provider): Namespace {
  const namespace = new Namespace(
    name,
    { metadata: buildNamespaceMetadata(name) },
    { provider: cluster },
  );

  if (clusterNamespaces[name].egress === 'deny') {
    createEgressDeny(name, namespace.metadata.name, cluster);
  }

  return namespace;
}
