import { expect, test } from 'bun:test';
import { geoffcloudNode } from '../shared/geoffcloud-node.ts';
import { buildNixieIngressValues } from './build-nixie-ingress-values.ts';

function setupTest() {
  // the forwarders' route: one count for every client, 4 requests at once, and 4 MiB of body each,
  // held in memory
  return {
    enabled: true,
    content: {
      http: {
        middlewares: {
          'pepys-forwarder-slot': {
            headers: { customRequestHeaders: { 'X-Pepys-Forwarder-Slot': 'route' } },
          },
          'pepys-forwarder-in-flight': {
            inFlightReq: {
              amount: 4,
              sourceCriterion: { requestHeaderName: 'X-Pepys-Forwarder-Slot' },
            },
          },
          'pepys-forwarder-body-limit': {
            buffering: { maxRequestBodyBytes: 4_194_304, memRequestBodyBytes: 4_194_304 },
          },
        },
      },
    },
  };
}

test("it holds the host's port 443, reads Ingress objects from the namespaces it is given and reports the host's tailnet address as their endpoint", () => {
  expect(
    buildNixieIngressValues({
      httpsPort: 443,
      endpointIP: '100.69.47.33',
      ingressClass: 'nixie',
      namespaces: ['nixie'],
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
      file: setupTest(),
      kubernetesGateway: { enabled: false },
      kubernetesIngress: {
        enabled: true,
        namespaces: ['nixie'],
        publishedService: { enabled: false },
        ingressEndpoint: { ip: '100.69.47.33' },
      },
    },
    ports: {
      web: { expose: { default: false } },
      websecure: { hostPort: 443 },
    },
    service: { spec: { type: 'ClusterIP' } },
  });
});

test("it builds the same release values from the registry's nixie-ingress port as from the 443 it held before", () => {
  expect(
    buildNixieIngressValues({
      httpsPort: geoffcloudNode.httpsPort,
      endpointIP: geoffcloudNode.ip,
      ingressClass: 'nixie',
      namespaces: ['nixie'],
    }),
  ).toStrictEqual(
    buildNixieIngressValues({
      httpsPort: 443,
      endpointIP: '100.69.47.33',
      ingressClass: 'nixie',
      namespaces: ['nixie'],
    }),
  );
});

test('it lets the shared Traefik watch both the nixie and the pepys namespaces', () => {
  expect(
    buildNixieIngressValues({
      httpsPort: 443,
      endpointIP: '100.69.47.33',
      ingressClass: 'nixie',
      namespaces: ['nixie', 'pepys'],
    })['providers'],
  ).toStrictEqual({
    kubernetesCRD: { enabled: false },
    file: setupTest(),
    kubernetesGateway: { enabled: false },
    kubernetesIngress: {
      enabled: true,
      namespaces: ['nixie', 'pepys'],
      publishedService: { enabled: false },
      ingressEndpoint: { ip: '100.69.47.33' },
    },
  });
});
