import type { CommandArgs } from '@pulumi/command/local';
import type { Output } from '@pulumi/pulumi';

export interface MCPTokenSyncInputs {
  readonly tokenID: Output<string>;
  readonly key: Output<string>;
}

// The deploy's service account cannot write the agents vault, so the copy runs only when the
// applier sets GRAFANA_MCP_OP_TOKEN to a token that can. op's stderr is dropped, because an op
// error can echo the field assignment that holds the key. op reads a piped stdin as a template.
const copyKey = [
  'if [ -z "$GRAFANA_MCP_OP_TOKEN" ]; then',
  "echo 'grafana-mcp-token-to-1password: skipped, GRAFANA_MCP_OP_TOKEN is unset; copy the token as docs/runbooks/workflows.md#rotate-a-credential describes' >&2; exit 0; fi;",
  'key=$(cat) && OP_SERVICE_ACCOUNT_TOKEN="$GRAFANA_MCP_OP_TOKEN"',
  'op item edit grafana-mcp --vault agents "credential=$key" < /dev/null > /dev/null 2>&1 ||',
  "{ echo 'grafana-mcp-token-to-1password: op could not write the grafana-mcp item in the agents vault' >&2; exit 1; }",
].join(' ');

export function buildMCPTokenSyncArgs(inputs: MCPTokenSyncInputs): CommandArgs {
  return {
    create: copyKey,
    stdin: inputs.key,

    // a no-op, so an edit to the command alone never copies the same token again; the Command's
    // resource options replace it when the trigger changes, which runs the copy for a new token
    update: ':',
    triggers: [inputs.tokenID],
    logging: 'stderr',
  };
}
