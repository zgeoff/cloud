import { Provider } from '@pulumi/kubernetes';
import type { ProviderArgs } from '@pulumi/kubernetes';
import { registerPortForwardGuard } from './register-port-forward-guard.ts';

export function createClusterProvider(name: string, args: ProviderArgs): Provider {
  // first, because a stack transform sees only the resources registered after it
  registerPortForwardGuard();

  return new Provider(name, args);
}
