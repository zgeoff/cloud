import { faker } from '@faker-js/faker';
import { output } from '@pulumi/pulumi';
import type { ATCGatewayOutputs } from '../cluster/atc-gateway.ts';

export function buildMockATCGatewayOutputs(
  overrides: Partial<ATCGatewayOutputs> = {},
): ATCGatewayOutputs {
  return {
    serviceURL: output(
      `http://${faker.internet.domainWord()}.atc.svc.cluster.local:${faker.internet.port()}`,
    ),
    publicHost: faker.internet.domainName(),
    ...overrides,
  };
}
