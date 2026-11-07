import { Command } from '@pulumi/command/local';
import type { Output, Resource } from '@pulumi/pulumi';
import { Provider, oss } from '@pulumiverse/grafana';
import { buildGrafanaProviderArgs } from './build-grafana-provider-args.ts';
import { buildMCPAccountArgs } from './build-mcp-account-args.ts';
import { buildMCPTokenSpec } from './build-mcp-token-spec.ts';
import { buildMCPTokenSyncArgs } from './build-mcp-token-sync-args.ts';

interface MCPServiceAccountInputs {
  readonly grafanaURL: string;
  readonly adminPassword: Output<string>;

  // the chart that runs Grafana, so the account goes into the Grafana that its rollout leaves
  readonly grafana: Resource;
}

export function createMCPServiceAccount(inputs: MCPServiceAccountInputs): Command {
  const provider = new Provider(
    'grafana',
    buildGrafanaProviderArgs(inputs.grafanaURL, inputs.adminPassword),
  );

  const account = new oss.ServiceAccount('mcp-viewer', buildMCPAccountArgs(), {
    provider,
    dependsOn: [inputs.grafana],
  });

  const tokenSpec = buildMCPTokenSpec({ accountID: account.id, provider, grafana: inputs.grafana });

  const token = new oss.ServiceAccountToken('mcp-viewer', tokenSpec.args, tokenSpec.options);

  return new Command(
    'grafana-mcp-token-to-1password',
    buildMCPTokenSyncArgs({ tokenID: token.id, key: token.key }),
  );
}
