import type {
  CustomResourceOptions,
  ProviderResource,
  ResourceOptions,
  ResourceTransform,
} from '@pulumi/pulumi';

// The provider replaces a ConfigMap or a Secret when its data changes, and a chart's children keep
// the fixed names the chart gives them, so a create before the delete fails with "already exists".
const replacedOnDataChange = new Set(['kubernetes:core/v1:ConfigMap', 'kubernetes:core/v1:Secret']);

export function makeDeleteBeforeReplaceTransform(provider: ProviderResource): ResourceTransform {
  return (args) =>
    replacedOnDataChange.has(args.type)
      ? { props: args.props, opts: buildDeleteBeforeReplaceOpts(args.opts, provider) }
      : undefined;
}

function buildDeleteBeforeReplaceOpts(
  opts: ResourceOptions,
  provider: ProviderResource,
): CustomResourceOptions {
  // Returned opts replace the child's whole, dropping the provider it inherits from the chart, so
  // they name it again. Pulumi reads deleteBeforeReplace from ResourceOptions for a custom
  // resource.
  return { ...opts, deleteBeforeReplace: true, provider };
}
