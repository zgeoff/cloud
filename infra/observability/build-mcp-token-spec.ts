import type { CustomResourceOptions, Output, ProviderResource, Resource } from '@pulumi/pulumi';
import type { oss } from '@pulumiverse/grafana';

export interface MCPTokenSpecInputs {
  readonly accountID: Output<string>;
  readonly provider: ProviderResource;
  readonly grafana: Resource;
}

interface MCPTokenSpec {
  readonly args: oss.ServiceAccountTokenArgs;
  readonly options: CustomResourceOptions;
}

export function buildMCPTokenSpec(inputs: MCPTokenSpecInputs): MCPTokenSpec {
  return {
    args: { name: 'mcp-viewer', serviceAccountId: inputs.accountID },
    options: {
      provider: inputs.provider,
      dependsOn: [inputs.grafana],

      // Grafana refuses a second token of the same name on one account, so a replace that creates
      // first fails
      deleteBeforeReplace: true,
    },
  };
}
