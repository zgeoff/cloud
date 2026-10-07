import { secret } from '@pulumi/pulumi';
import type { Output } from '@pulumi/pulumi';
import type { ATCGatewayInputs } from './atc-gateway.ts';
import { loadATCGatewayInputs } from './load-atc-gateway-inputs.ts';
import { requireKubeconfig } from './require-kubeconfig.ts';
import { requireOnePasswordConnectCredentials } from './require-onepassword-connect-credentials.ts';

interface ClusterConfigInputs {
  readonly kubeconfig: string;
  readonly atcGateway?: ATCGatewayInputs;

  // the 1Password Connect server's credentials file
  readonly onePasswordConnectCredentials: Output<string>;
}

// What a managed cluster needs from the stack config and the environment, or nothing when
// the stack leaves the cluster out. Everything is checked here, at the top of the program,
// so a missing value fails the run before any resource registers, instead of planning to
// delete the cluster's resources.
export function loadClusterInputs(
  mode: string | undefined,
  env: NodeJS.ProcessEnv,
): ClusterConfigInputs | undefined {
  const kubeconfig = requireKubeconfig(mode, env['K3S_KUBECONFIG']);

  if (kubeconfig === undefined) {
    return undefined;
  }

  return {
    kubeconfig,
    onePasswordConnectCredentials: secret(
      requireOnePasswordConnectCredentials(env['ONEPASSWORD_CONNECT_CREDENTIALS']),
    ),
    ...loadATCGatewayInputs(),
  };
}
