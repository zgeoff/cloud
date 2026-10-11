import { expect, test } from 'bun:test';
import { buildNixieIngressValues } from './build-nixie-ingress-values.ts';

test("it holds the host's port 443 and reads Ingress objects from nixie's namespace alone", () => {
  expect(
    buildNixieIngressValues({
      httpsPort: 443,
      ingressClass: 'nixie',
      namespace: 'nixie',
    }),
  ).toStrictEqual({
    image: { digest: 'sha256:24841fe2de7304c149343d877d2923b4c8800a38ba015dea9174c23b20e344a0' },
    versionOverride: 'v3.7.13',
    deployment: { replicas: 1 },
    updateStrategy: { type: 'RollingUpdate', rollingUpdate: { maxUnavailable: 1, maxSurge: 0 } },
    ingressClass: { enabled: true, isDefaultClass: false, name: 'nixie' },
    gateway: { enabled: false },
    gatewayClass: { enabled: false },
    api: { dashboard: false },
    providers: {
      kubernetesCRD: { enabled: false },
      kubernetesGateway: { enabled: false },
      kubernetesIngress: { enabled: true, namespaces: ['nixie'] },
    },
    ports: {
      web: { expose: { default: false } },
      websecure: { hostPort: 443 },
    },
    service: { spec: { type: 'ClusterIP' } },
  });
});
