import { expect, onTestFinished, test } from 'bun:test';
import { isSecret, runtime } from '@pulumi/pulumi';
import { resolveOutput } from '../test-utils/resolve-output.ts';
import { createATCTunnel } from './create-atc-tunnel.ts';

test("it returns the tunnel's connector token as a secret", async () => {
  await runtime.setMocks(
    {
      newResource: () => ({ id: 'atc-tunnel', state: {} }),
      call: () => ({ token: 'atc-tunnel-token-4f2a' }),
    },
    'geoff-cloud',
    'test',
  );

  onTestFinished(() => {
    runtime.resetOptions('', '', -1, '', '', false, '');
  });

  const tunnel = createATCTunnel('account');

  expect(isSecret(tunnel.tunnelToken)).resolves.toBeTrue();
  expect(resolveOutput(tunnel.tunnelToken)).resolves.toBe('atc-tunnel-token-4f2a');
});
