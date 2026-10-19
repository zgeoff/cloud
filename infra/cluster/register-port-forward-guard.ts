import type { ResourceTransform } from '@pulumi/pulumi';
import { runtime } from '@pulumi/pulumi';
import { requireNoPortForwardGrant } from './require-no-port-forward-grant.ts';

// Fails the preview on any RBAC object that grants pods/portforward. A stack transform sees every
// resource registered after it, the Helm charts' rendered objects included, so the program root
// calls this before it declares any resource. register is Pulumi's stack-transform registry.
export function registerPortForwardGuard(
  register: (transform: ResourceTransform) => void = runtime.registerResourceTransform,
): void {
  register((args) => {
    requireNoPortForwardGrant(args.type, args.props);
  });
}
