import type { Output } from '@pulumi/pulumi';
import { toATCGatewayTokenVariable } from '../inputs/index.ts';

export function buildATCGatewayTokenData(
  tokens: Readonly<Record<string, Output<string>>>,
): Record<string, Output<string>> {
  return Object.fromEntries(
    Object.entries(tokens).map(([name, token]) => [toATCGatewayTokenVariable(name), token]),
  );
}
