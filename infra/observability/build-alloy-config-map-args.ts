import type { ConfigMapArgs } from '@pulumi/kubernetes/core/v1';
import type { Input } from '@pulumi/pulumi';
import { alloyConfigKey } from './alloy-config-key.ts';
import { alloyConfig } from './alloy-config.ts';

export function buildAlloyConfigMapArgs(namespace: Input<string>): ConfigMapArgs {
  return {
    // No name: the provider replaces a ConfigMap when its data changes, creating the new one
    // before it deletes the old, so no create meets a name that exists.
    metadata: { namespace },
    data: { [alloyConfigKey]: alloyConfig },
  };
}
