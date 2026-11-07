import { expect, test } from 'bun:test';
import { output, secret } from '@pulumi/pulumi';
import { buildMCPTokenSyncArgs } from './build-mcp-token-sync-args.ts';

test('it writes the key from stdin to the credential field of the zgeoff grafana-mcp item, runs again only for a new token, and logs nothing', () => {
  const tokenID = output('1:7');
  const key = secret('glsa_example');

  expect(buildMCPTokenSyncArgs({ tokenID, key })).toStrictEqual({
    create:
      'key=$(cat) && op item edit grafana-mcp --vault zgeoff "credential=$key" < /dev/null > /dev/null',
    stdin: key,
    triggers: [tokenID],
    logging: 'none',
  });
});
