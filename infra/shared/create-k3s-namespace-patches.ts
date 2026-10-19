import type { Provider } from '@pulumi/kubernetes';
import { NamespacePatch } from '@pulumi/kubernetes/core/v1';
import { buildNamespaceMetadata } from './build-namespace-metadata.ts';
import { collectK3sLabelledNamespaces } from './collect-k3s-labelled-namespaces.ts';

// Labels each namespace k3s creates, such as default, through a server-side apply patch: Pulumi
// owns the labels and never the namespace, so a destroy removes the labels and keeps the namespace
export function createK3sNamespacePatches(cluster: Provider): NamespacePatch[] {
  return collectK3sLabelledNamespaces().map(
    (name) =>
      new NamespacePatch(name, { metadata: buildNamespaceMetadata(name) }, { provider: cluster }),
  );
}
