import { expect, test } from 'bun:test';
import { output } from '@pulumi/pulumi';
import { buildATCGatewayRouteOutputs } from './build-atc-gateway-route-outputs.ts';
import { buildMockATCGatewayOutputs } from './test-utils/build-mock-atc-gateway-outputs.ts';

test("it routes the public host to the gateway's service and health-checks its OAuth resource metadata", () => {
  const serviceURL = output('http://atc-gateway.atc.svc.cluster.local:8414');

  expect(
    buildATCGatewayRouteOutputs(
      buildMockATCGatewayOutputs({ serviceURL, publicHost: 'atc.geoff.cloud' }),
    ),
  ).toStrictEqual({
    atcGatewayServiceURL: serviceURL,
    atcGatewayRoute: {
      hostname: 'atc.geoff.cloud',
      service: serviceURL,
      healthURL: 'https://atc.geoff.cloud/.well-known/oauth-protected-resource/mcp',
    },
  });
});
