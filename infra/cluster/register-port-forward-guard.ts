import type { ResourceTransform } from '@pulumi/pulumi';
import { runtime } from '@pulumi/pulumi';
import { requireNoPortForwardGrant } from './require-no-port-forward-grant.ts';

export function registerPortForwardGuard(
  register: (transform: ResourceTransform) => void = runtime.registerResourceTransform,
): void {
  register((args) => {
    requireNoPortForwardGrant(args.type, args.props);
  });
}
