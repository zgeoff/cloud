import { Provider } from '@pulumi/kubernetes';
import type { ProviderArgs } from '@pulumi/kubernetes';
import { registerPortForwardGuard } from './register-port-forward-guard.ts';

// The cluster's Kubernetes provider. It registers the port-forward guard first, so the program
// cannot declare a Kubernetes resource without the guard: every resource registered after it, a
// Helm chart's rendered objects included, passes through the guard.
export function createClusterProvider(name: string, args: ProviderArgs): Provider {
  registerPortForwardGuard();

  return new Provider(name, args);
}
