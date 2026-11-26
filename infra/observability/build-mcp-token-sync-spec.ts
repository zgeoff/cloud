import type { CommandArgs } from '@pulumi/command/local';
import type { CustomResourceOptions, Output } from '@pulumi/pulumi';

export interface MCPTokenSyncInputs {
  readonly tokenID: Output<string>;
  readonly key: Output<string>;
}

interface MCPTokenSyncSpec {
  readonly args: CommandArgs;
  readonly options: CustomResourceOptions;
}

// The deploy's service account cannot write the agents vault, so only an applier with a token that
// can sets GRAFANA_MCP_OP_TOKEN. An op error and a trace can echo the key, so both stay off. op
// reads a piped stdin as an item template, so the key is read first and stdin closed.
const copyKey = [
  'set +x;',
  'if [ -z "$GRAFANA_MCP_OP_TOKEN" ]; then',
  "echo 'grafana-mcp-token-to-1password: skipped, GRAFANA_MCP_OP_TOKEN is unset; copy the token as docs/runbooks/workflows.md#rotate-a-credential describes' >&2; exit 0; fi;",
  'key=$(cat) && OP_SERVICE_ACCOUNT_TOKEN="$GRAFANA_MCP_OP_TOKEN"',
  'op item edit grafana-mcp --vault agents "credential=$key" < /dev/null > /dev/null 2>&1 ||',
  "{ echo 'grafana-mcp-token-to-1password: op could not write the grafana-mcp item in the agents vault' >&2; exit 1; }",
].join(' ');

export function buildMCPTokenSyncSpec(inputs: MCPTokenSyncInputs): MCPTokenSyncSpec {
  return {
    args: {
      create: copyKey,
      stdin: inputs.key,

      // pulumi-command runs create again on an update with no update command, so an edit to the
      // command text alone would copy the same token again
      update: ':',
      triggers: [inputs.tokenID],
      logging: 'stderr',
    },

    // with an update command set, a changed trigger only updates, so a new token would not be copied
    options: { replaceOnChanges: ['triggers'] },
  };
}
