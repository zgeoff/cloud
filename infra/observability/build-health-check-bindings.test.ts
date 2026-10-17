import { expect, test } from 'bun:test';
import { Output, isSecret, output } from '@pulumi/pulumi';
import invariant from 'tiny-invariant';
import { resolveOutput } from '../test-utils/resolve-output.ts';
import { buildHealthCheckBindings } from './build-health-check-bindings.ts';

test('it binds the state bucket, the targets as JSON and the alert webhook when one is set', () => {
  const stateBucket = output('geoff-cloud-health-check-state');

  expect(
    buildHealthCheckBindings({
      stateBucket,
      targets: [
        { name: 'atc', url: 'https://atc.geoff.cloud/.well-known/oauth-protected-resource/mcp' },
      ],
      alertURL: 'https://discord.com/api/webhooks/1/abc',
    }),
  ).toStrictEqual([
    { name: 'STATE', type: 'r2_bucket', bucketName: stateBucket },
    {
      name: 'TARGETS',
      type: 'plain_text',
      text: '[{"name":"atc","url":"https://atc.geoff.cloud/.well-known/oauth-protected-resource/mcp"}]',
    },
    {
      name: 'ALERT_URL',
      type: 'secret_text',
      text: expect.toSatisfy((value: unknown) => Output.isInstance(value)),
    },
  ]);
});

test('it marks the alert webhook binding secret', () => {
  const bindings = buildHealthCheckBindings({
    stateBucket: output('geoff-cloud-health-check-state'),
    targets: [],
    alertURL: 'https://discord.com/api/webhooks/1/abc',
  });

  const alert = bindings.find((binding) => binding.name === 'ALERT_URL');

  invariant(alert?.type === 'secret_text', 'expected the ALERT_URL binding');

  expect(isSecret(alert.text)).resolves.toBeTrue();
});

test('it binds the alert webhook URL as given', () => {
  const bindings = buildHealthCheckBindings({
    stateBucket: output('geoff-cloud-health-check-state'),
    targets: [],
    alertURL: 'https://discord.com/api/webhooks/1/abc',
  });

  const alert = bindings.find((binding) => binding.name === 'ALERT_URL');

  invariant(alert?.type === 'secret_text', 'expected the ALERT_URL binding');

  expect(resolveOutput(alert.text)).resolves.toBe('https://discord.com/api/webhooks/1/abc');
});

test('it leaves ALERT_URL out when no webhook is set', () => {
  const stateBucket = output('geoff-cloud-health-check-state');

  expect(buildHealthCheckBindings({ stateBucket, targets: [], alertURL: undefined })).toStrictEqual(
    [
      { name: 'STATE', type: 'r2_bucket', bucketName: stateBucket },
      { name: 'TARGETS', type: 'plain_text', text: '[]' },
    ],
  );
});
