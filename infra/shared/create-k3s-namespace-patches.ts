import type { Provider } from '@pulumi/kubernetes';
import { NamespacePatch } from '@pulumi/kubernetes/core/v1';
import { buildNamespaceMetadata } from './build-namespace-metadata.ts';
import { collectK3sLabelledNamespaces } from './collect-k3s-labelled-namespaces.ts';

export function createK3sNamespacePatches(cluster: Provider): NamespacePatch[] {
  // a server-side apply patch: Pulumi owns the labels and never the namespace, so a destroy removes
  // the labels and keeps the namespace
  return collectK3sLabelledNamespaces().map(
    (name) =>
      new NamespacePatch(name, { metadata: buildNamespaceMetadata(name) }, { provider: cluster }),
  );
}
