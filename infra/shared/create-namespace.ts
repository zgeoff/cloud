import type { Provider } from '@pulumi/kubernetes';
import { Namespace } from '@pulumi/kubernetes/core/v1';
import { buildNamespaceMetadata } from './build-namespace-metadata.ts';
import type { PulumiNamespace } from './cluster-namespaces.ts';

// The one place the program declares a Namespace, so each carries its Pod Security labels; a lint
// rule refuses the Namespace import anywhere else
export function createNamespace(name: PulumiNamespace, cluster: Provider): Namespace {
  return new Namespace(name, { metadata: buildNamespaceMetadata(name) }, { provider: cluster });
}
