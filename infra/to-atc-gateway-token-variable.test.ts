import { expect, test } from 'bun:test';
import { toATCGatewayTokenVariable } from './to-atc-gateway-token-variable.ts';

test.each([
  ['geoffcloud', 'ATC_GATEWAY_TOKEN_GEOFFCLOUD'],
  ['home-pc', 'ATC_GATEWAY_TOKEN_HOME_PC'],
  ['home-pc-2', 'ATC_GATEWAY_TOKEN_HOME_PC_2'],
])("it reads daemon %s's token from %s", (name, expected) => {
  expect(toATCGatewayTokenVariable(name)).toBe(expected);
});
