import type { CustomResourceOptions, ResourceOptions, ResourceTransform } from '@pulumi/pulumi';

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
  // deletes before it replaces, since two Traefik pods cannot hold the host's port at once
  return { ...opts, aliases: [{ name: previousName }], deleteBeforeReplace: true };
}
