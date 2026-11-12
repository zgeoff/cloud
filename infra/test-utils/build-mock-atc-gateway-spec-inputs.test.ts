import { expect, test } from 'bun:test';
import { buildMockATCGatewaySpecInputs } from './build-mock-atc-gateway-spec-inputs.ts';

test('it builds inputs with the public host of the config and no service token Secret', () => {
  const inputs = buildMockATCGatewaySpecInputs();

  expect(inputs.config.publicURL).toBe(`https://${inputs.publicHost}`);
  expect(inputs).not.toHaveProperty('serviceTokens');
});
