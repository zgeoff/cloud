import { expect, test } from 'bun:test';
import { output } from '@pulumi/pulumi';
import { buildATCGatewayTokenData } from './build-atc-gateway-token-data.ts';

test("it keys each daemon's token by the ATC_GATEWAY_TOKEN_<NAME> variable the gateway reads", () => {
  const geoffcloud = output('g'.repeat(32));
  const homePC = output('h'.repeat(32));

  expect(buildATCGatewayTokenData({ geoffcloud, 'home-pc': homePC })).toStrictEqual({
    ATC_GATEWAY_TOKEN_GEOFFCLOUD: geoffcloud,
    ATC_GATEWAY_TOKEN_HOME_PC: homePC,
  });
});

test('it holds no key without daemons', () => {
  expect(buildATCGatewayTokenData({})).toStrictEqual({});
});
