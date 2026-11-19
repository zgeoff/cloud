import { output } from '@pulumi/pulumi';
import { buildMockATCGatewayConfig } from './build-mock-atc-gateway-config.ts';

// the inputs of the gateway's Deployment spec, with a 7.14.0 image, the backup image the init
// container of a service token runs, and fixed names for the objects it mounts
export function buildMockATCGatewaySpecInputs() {
  return {
    config: buildMockATCGatewayConfig({
      image:
        'ghcr.io/zgeoff/atc-gateway:7.14.0@sha256:0000000000000000000000000000000000000000000000000000000000000000',
      backupImage:
        'ghcr.io/zgeoff/atc-gateway-backup:2.24.0-r2@sha256:1111111111111111111111111111111111111111111111111111111111111111',
      publicURL: 'https://atc.geoff.cloud',
      stateDir: '/var/lib/atc-gateway',
      trustForwardedFrom: ['127.0.0.1'],
    }),
    publicHost: 'atc.geoff.cloud',
    claim: output('atc-gateway-state'),
    tokens: output('atc-gateway-daemon-tokens-0a1b2c3d'),
    registry: output('atc-gateway-registry-4e5f6a7b'),
    pullSecret: output('ghcr-pull'),
    tunnelToken: output('atc-tunnel-token-8c9d0e1f'),
  };
}
