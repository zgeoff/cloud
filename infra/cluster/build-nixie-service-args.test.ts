import { expect, test } from 'bun:test';
import { output } from '@pulumi/pulumi';
import { buildNixieServiceArgs } from './build-nixie-service-args.ts';

test('it selects the labelled Pods on their http port and tells Pulumi not to wait for them', () => {
  const namespace = output('nixie');

  expect(
    buildNixieServiceArgs({ name: 'nixie', namespace, labels: { app: 'nixie' }, port: 8080 }),
  ).toStrictEqual({
    metadata: {
      name: 'nixie',
      namespace,
      annotations: { 'pulumi.com/skipAwait': 'true' },
    },
    spec: {
      selector: { app: 'nixie' },
      ports: [{ name: 'http', port: 8080, targetPort: 'http' }],
    },
  });
});
