import type { CommandArgs } from '@pulumi/command/local';
import type { Output } from '@pulumi/pulumi';

export interface MCPTokenSyncInputs {
  readonly tokenID: Output<string>;
  readonly key: Output<string>;
}

export function buildMCPTokenSyncArgs(inputs: MCPTokenSyncInputs): CommandArgs {
  return {
    // op treats a piped stdin as a JSON template, so read the key first
    create:
      'key=$(cat) && op item edit grafana-mcp --vault zgeoff "credential=$key" < /dev/null > /dev/null',
    stdin: inputs.key,

    // a trigger, not an update: a new token replaces the Command, which the prod deploy's guard
    // holds, because the deploy's service account cannot write the zgeoff vault
    triggers: [inputs.tokenID],
    logging: 'none',
  };
}
