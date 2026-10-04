import { describe, expect, test } from 'bun:test';
import { toATCGatewayTokenVariable } from './to-atc-gateway-token-variable.ts';

describe('toATCGatewayTokenVariable', () => {
  test("names the variable atc reads: the name upper-cased, '-' as '_'", () => {
    expect(toATCGatewayTokenVariable('geoffcloud')).toBe('ATC_GATEWAY_TOKEN_GEOFFCLOUD');
    expect(toATCGatewayTokenVariable('home-pc')).toBe('ATC_GATEWAY_TOKEN_HOME_PC');
  });
});
