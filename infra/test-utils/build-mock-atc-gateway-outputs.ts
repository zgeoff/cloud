import { faker } from '@faker-js/faker';
import { output } from '@pulumi/pulumi';
import type { ATCGatewayOutputs } from '../atc-gateway.ts';

// The plain fields of the gateway's outputs, the ones a builder takes. deployment and
// backupJob are Pulumi resources, which a factory cannot build without registering them.
type ATCGatewayPlainOutputs = Pick<ATCGatewayOutputs, 'serviceURL' | 'publicHost'>;

export function buildMockATCGatewayOutputs(
  overrides: Partial<ATCGatewayPlainOutputs> = {},
): ATCGatewayPlainOutputs {
  return {
    serviceURL: output(
      `http://${faker.internet.domainWord()}.atc.svc.cluster.local:${faker.internet.port()}`,
    ),
    publicHost: faker.internet.domainName(),
    ...overrides,
  };
}
