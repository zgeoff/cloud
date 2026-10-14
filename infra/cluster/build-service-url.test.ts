import { expect, test } from 'bun:test';
import { output } from '@pulumi/pulumi';
import { resolveOutput } from '../test-utils/resolve-output.ts';
import { buildServiceURL } from './build-service-url.ts';

test("it builds the Service's cluster DNS URL on the given port", async () => {
  const url = buildServiceURL({ name: output('atc-gateway'), namespace: output('atc') }, 8414);

  const resolved = await resolveOutput(url);

  expect(resolved).toBe('http://atc-gateway.atc.svc.cluster.local:8414');
});
