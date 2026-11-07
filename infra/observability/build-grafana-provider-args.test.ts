import { expect, test } from 'bun:test';
import { isSecret, output } from '@pulumi/pulumi';
import { resolveOutput } from '../test-utils/resolve-output.ts';
import { buildGrafanaProviderArgs } from './build-grafana-provider-args.ts';

test('it signs in to Grafana at the URL as admin with the admin password', async () => {
  const args = buildGrafanaProviderArgs('http://100.64.0.9:30300', output('admin-password'));

  const auth = await resolveOutput(args.auth);

  expect({ url: args.url, auth }).toStrictEqual({
    url: 'http://100.64.0.9:30300',
    auth: 'admin:admin-password',
  });
});

test('it keeps the sign-in secret when the admin password is not', async () => {
  const args = buildGrafanaProviderArgs('http://100.64.0.9:30300', output('admin-password'));

  const secret = await isSecret(args.auth);

  expect(secret).toBeTrue();
});
