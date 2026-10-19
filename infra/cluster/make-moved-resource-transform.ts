import type { CustomResourceOptions, ResourceOptions, ResourceTransform } from '@pulumi/pulumi';

// Makes a transform that ties one chart child to the Pulumi name it had before a move, and deletes
// the old object before it creates the new one, since two Traefik pods cannot hold the host's port
// at once. Other resources pass through.
export function makeMovedResourceTransform(
  type: string,
  name: string,
  previousName: string,
): ResourceTransform {
  return (args) =>
    args.type === type && args.name === name
      ? { props: args.props, opts: buildMovedOptions(args.opts, previousName) }
      : undefined;
}

function buildMovedOptions(opts: ResourceOptions, previousName: string): CustomResourceOptions {
  return { ...opts, aliases: [{ name: previousName }], deleteBeforeReplace: true };
}
