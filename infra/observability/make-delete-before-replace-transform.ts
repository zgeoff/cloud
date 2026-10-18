import type {
  CustomResourceOptions,
  ProviderResource,
  ResourceOptions,
  ResourceTransform,
} from '@pulumi/pulumi';

// The provider replaces a ConfigMap or a Secret when its data changes, and a chart's children keep
// the fixed names the chart gives them, so a create before the delete fails with "already exists".
const replacedOnDataChange = new Set(['kubernetes:core/v1:ConfigMap', 'kubernetes:core/v1:Secret']);

// Makes a transform that deletes a chart's ConfigMap or Secret before it creates its replacement.
// The consumer reads the old object until the delete, and the new one from the create, a moment
// later. Other resources pass through.
export function makeDeleteBeforeReplaceTransform(provider: ProviderResource): ResourceTransform {
  return (args) =>
    replacedOnDataChange.has(args.type)
      ? { props: args.props, opts: buildDeleteBeforeReplaceOpts(args.opts, provider) }
      : undefined;
}

// Returned opts replace the child's whole, dropping the provider it inherits from the chart, so
// they name that provider again. A transform's opts are typed ResourceOptions, and Pulumi reads
// deleteBeforeReplace from them for a custom resource.
function buildDeleteBeforeReplaceOpts(
  opts: ResourceOptions,
  provider: ProviderResource,
): CustomResourceOptions {
  return { ...opts, deleteBeforeReplace: true, provider };
}
