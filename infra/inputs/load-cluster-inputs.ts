import { secret } from '@pulumi/pulumi';
import type { Output } from '@pulumi/pulumi';
import { loadATCGatewayInputs } from './load-atc-gateway-inputs.ts';
import { loadFilesInputs } from './load-files-inputs.ts';
import { loadNixieInputs } from './load-nixie-inputs.ts';
import { requireKubeconfig } from './require-kubeconfig.ts';
import { requireOnePasswordConnectCredentials } from './require-onepassword-connect-credentials.ts';
import type {
  ATCGatewayInputs,
  Environment,
  FilesInputs,
  NixieInputs,
  StackConfig,
} from './types.ts';

interface ClusterConfigInputs {
  readonly kubeconfig: string;
  readonly atcGateway?: ATCGatewayInputs;
  readonly nixie?: NixieInputs;
  readonly files?: FilesInputs;

  // the 1Password Connect server's credentials file
  readonly onePasswordConnectCredentials: Output<string>;
}

// checked at the top of the program, so a missing value fails before any resource registers
// instead of planning to delete the cluster's resources
export function loadClusterInputs(
  stackConfig: Pick<StackConfig, 'get' | 'getObject' | 'getSecret'>,
  env: Environment,
): ClusterConfigInputs | undefined {
  const kubeconfig = requireKubeconfig(stackConfig.get('cluster'), env);

  if (kubeconfig === undefined) {
    return undefined;
  }

  // the Connect credentials first, so a missing file fails before the gateway's config
  const onePasswordConnectCredentials = secret(requireOnePasswordConnectCredentials(env));
  const atcGateway = loadATCGatewayInputs(stackConfig, env);

  const backupImage =
    atcGateway.atcGateway === undefined
      ? undefined
      : {
          reference: atcGateway.atcGateway.config.backupImage,
          pullCredential: atcGateway.atcGateway.secrets.pullCredential,
        };

  return {
    kubeconfig,
    onePasswordConnectCredentials,
    ...atcGateway,
    ...loadNixieInputs(stackConfig, env, backupImage),
    ...loadFilesInputs(stackConfig, env, backupImage),
  };
}
