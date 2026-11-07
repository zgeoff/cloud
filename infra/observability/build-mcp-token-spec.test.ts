import { expect, onTestFinished, test } from 'bun:test';
import { Command } from '@pulumi/command/local';
import { output, runtime } from '@pulumi/pulumi';
import { Provider } from '@pulumiverse/grafana';
import { buildStubResourceMocks } from '../test-utils/build-stub-resource-mocks.ts';
import { buildMCPTokenSpec } from './build-mcp-token-spec.ts';

async function setupTest() {
  const stub = buildStubResourceMocks();

  await runtime.setMocks(stub.mocks, 'geoff-cloud', 'test');

  onTestFinished(() => {
    stub.release();
    runtime.resetOptions('', '', -1, '', '', false, '');
  });

  return { stub };
}

test('it ties the token to the account, after Grafana, and deletes the old token before its replacement', async () => {
  await setupTest();

  const accountID = output('1');

  const provider = new Provider('grafana', { url: 'http://100.64.0.9:30300' });
  const grafana = new Command('grafana', { create: 'true' });

  expect(buildMCPTokenSpec({ accountID, provider, grafana })).toStrictEqual({
    args: { name: 'mcp-viewer', serviceAccountId: accountID },
    options: { provider, dependsOn: [grafana], deleteBeforeReplace: true },
  });
});
