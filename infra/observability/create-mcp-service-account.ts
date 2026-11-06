import { Command } from '@pulumi/command/local';
import type { Output, Resource } from '@pulumi/pulumi';
import { Provider, oss } from '@pulumiverse/grafana';
import { buildGrafanaProviderArgs } from './build-grafana-provider-args.ts';
import { buildMCPTokenSyncArgs } from './build-mcp-token-sync-args.ts';

interface MCPServiceAccountInputs {
  readonly grafanaURL: string;
  readonly adminPassword: Output<string>;

  // the chart that runs Grafana, so the account goes into the Grafana that its rollout leaves
  readonly grafana: Resource;
}

// a Viewer account for an MCP server that only reads: its queries work, and every write gets 403
export function createMCPServiceAccount(inputs: MCPServiceAccountInputs): Command {
  const provider = new Provider(
    'grafana',
    buildGrafanaProviderArgs(inputs.grafanaURL, inputs.adminPassword),
  );

  const opts = { provider, dependsOn: [inputs.grafana] };

  const account = new oss.ServiceAccount(
    'mcp-viewer',
    { name: 'mcp-viewer', role: 'Viewer' },
    opts,
  );

  const token = new oss.ServiceAccountToken(
    'mcp-viewer',
    { name: 'mcp-viewer', serviceAccountId: account.id },
    opts,
  );

  return new Command(
    'grafana-mcp-token-to-1password',
    buildMCPTokenSyncArgs({ tokenID: token.id, key: token.key }),
  );
}
