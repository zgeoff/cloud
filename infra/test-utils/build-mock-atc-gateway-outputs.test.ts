import { expect, test } from 'bun:test';
import { Output } from '@pulumi/pulumi';
import { buildMockATCGatewayOutputs } from './build-mock-atc-gateway-outputs.ts';

test('it builds default atc gateway outputs', () => {
  expect(buildMockATCGatewayOutputs()).toStrictEqual({
    serviceURL: expect.toSatisfy((serviceURL: unknown) => Output.isInstance(serviceURL)),
    publicHost: expect.toSatisfy((host: string) => /^[\w-]+(?:\.[\w-]+)+$/u.test(host)),
  });
});

test('it applies overrides on top of the defaults', () => {
  expect(buildMockATCGatewayOutputs({ publicHost: 'atc.geoff.cloud' })).toStrictEqual({
    serviceURL: expect.toSatisfy((serviceURL: unknown) => Output.isInstance(serviceURL)),
    publicHost: 'atc.geoff.cloud',
  });
});
