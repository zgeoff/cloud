import type { ConfigMapArgs } from '@pulumi/kubernetes/core/v1';
import type { Input } from '@pulumi/pulumi';
import { alloyConfigKey } from './alloy-config-key.ts';
import { alloyConfig } from './alloy-config.ts';

// Alloy's ConfigMap in namespace, with no name: Pulumi names it, and the provider replaces a
// ConfigMap when its data changes, so each config change creates a ConfigMap under a new name before
// it deletes the old one, and no create meets a name that exists.
export function buildAlloyConfigMapArgs(namespace: Input<string>): ConfigMapArgs {
  return {
    metadata: { namespace },
    data: { [alloyConfigKey]: alloyConfig },
  };
}
