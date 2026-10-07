// each test asserts a hand-written spec whole, as one literal, so its body is long
/* oxlint-disable max-lines-per-function */
import { expect, test } from 'bun:test';
import { output } from '@pulumi/pulumi';
import { buildATCGatewaySpec, buildATCPodSecurity } from './build-atc-gateway-spec.ts';
import { buildMockATCGatewayConfig } from './test-utils/build-mock-atc-gateway-config.ts';

test("#buildATCGatewaySpec keeps state in $HOME's state dir when the config sets no stateDir, passing the claim, tokens and registry through", () => {
  const claim = output('atc-gateway-state');
  const tokens = output('atc-gateway-daemon-tokens-0a1b2c3d');
  const registry = output('atc-gateway-registry-4e5f6a7b');

  expect(
    buildATCGatewaySpec({
      config: buildMockATCGatewayConfig({
        image:
          'ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000',
        publicURL: 'https://atc.geoff.cloud',
      }),
      claim,
      tokens,
      registry,
    }),
  ).toStrictEqual({
    replicas: 1,
    strategy: { type: 'Recreate' },
    selector: { matchLabels: { app: 'atc-gateway' } },
    template: {
      metadata: { labels: { app: 'atc-gateway' } },
      spec: {
        securityContext: {
          runAsNonRoot: true,
          runAsUser: 65_532,
          runAsGroup: 65_532,
          fsGroup: 65_532,
          seccompProfile: { type: 'RuntimeDefault' },
        },
        automountServiceAccountToken: false,
        containers: [
          {
            name: 'atc-gateway',
            image:
              'ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000',
            args: [
              'serve',
              '--host',
              '0.0.0.0',
              '--port',
              '8414',
              '--public-url',
              'https://atc.geoff.cloud',
              '--registry',
              '/etc/atc-gateway/registry.json',
              '--state-dir',
              '/home/nonroot/.local/state/atc',
            ],
            ports: [{ name: 'http', containerPort: 8414 }],
            envFrom: [{ secretRef: { name: tokens } }],
            env: [{ name: 'ATC_GATEWAY_STATE_DIR', value: '/home/nonroot/.local/state/atc' }],
            volumeMounts: [
              { name: 'state', mountPath: '/home/nonroot/.local/state/atc' },
              { name: 'config', mountPath: '/home/nonroot/.config' },
              { name: 'runtime', mountPath: '/run/atc' },
              { name: 'tmp', mountPath: '/tmp' },
              { name: 'registry', mountPath: '/etc/atc-gateway', readOnly: true },
            ],
            livenessProbe: {
              httpGet: {
                path: '/healthz',
                port: 8414,
                httpHeaders: [{ name: 'Host', value: 'atc.geoff.cloud' }],
              },
              periodSeconds: 20,
              failureThreshold: 3,
            },
            readinessProbe: {
              httpGet: {
                path: '/readyz',
                port: 8414,
                httpHeaders: [{ name: 'Host', value: 'atc.geoff.cloud' }],
              },
              periodSeconds: 10,
            },
            resources: { requests: { cpu: '50m', memory: '128Mi' }, limits: { memory: '256Mi' } },
            securityContext: {
              readOnlyRootFilesystem: true,
              allowPrivilegeEscalation: false,
              capabilities: { drop: ['ALL'] },
            },
          },
        ],
        volumes: [
          { name: 'state', persistentVolumeClaim: { claimName: claim } },
          { name: 'config', emptyDir: {} },
          { name: 'runtime', emptyDir: { medium: 'Memory' } },
          { name: 'tmp', emptyDir: {} },
          { name: 'registry', configMap: { name: registry } },
        ],
      },
    },
  });
});

test('#buildATCGatewaySpec mounts the state volume at the stateDir the config sets and points the gateway at it', () => {
  const claim = output('atc-gateway-state');
  const tokens = output('atc-gateway-daemon-tokens-0a1b2c3d');
  const registry = output('atc-gateway-registry-4e5f6a7b');

  expect(
    buildATCGatewaySpec({
      config: buildMockATCGatewayConfig({
        image:
          'ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000',
        publicURL: 'https://atc.geoff.cloud',
        stateDir: '/var/lib/atc-gateway',
      }),
      claim,
      tokens,
      registry,
    }),
  ).toStrictEqual({
    replicas: 1,
    strategy: { type: 'Recreate' },
    selector: { matchLabels: { app: 'atc-gateway' } },
    template: {
      metadata: { labels: { app: 'atc-gateway' } },
      spec: {
        securityContext: {
          runAsNonRoot: true,
          runAsUser: 65_532,
          runAsGroup: 65_532,
          fsGroup: 65_532,
          seccompProfile: { type: 'RuntimeDefault' },
        },
        automountServiceAccountToken: false,
        containers: [
          {
            name: 'atc-gateway',
            image:
              'ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000',
            args: [
              'serve',
              '--host',
              '0.0.0.0',
              '--port',
              '8414',
              '--public-url',
              'https://atc.geoff.cloud',
              '--registry',
              '/etc/atc-gateway/registry.json',
              '--state-dir',
              '/var/lib/atc-gateway',
            ],
            ports: [{ name: 'http', containerPort: 8414 }],
            envFrom: [{ secretRef: { name: tokens } }],
            env: [{ name: 'ATC_GATEWAY_STATE_DIR', value: '/var/lib/atc-gateway' }],
            volumeMounts: [
              { name: 'state', mountPath: '/var/lib/atc-gateway' },
              { name: 'config', mountPath: '/home/nonroot/.config' },
              { name: 'runtime', mountPath: '/run/atc' },
              { name: 'tmp', mountPath: '/tmp' },
              { name: 'registry', mountPath: '/etc/atc-gateway', readOnly: true },
            ],
            livenessProbe: {
              httpGet: {
                path: '/healthz',
                port: 8414,
                httpHeaders: [{ name: 'Host', value: 'atc.geoff.cloud' }],
              },
              periodSeconds: 20,
              failureThreshold: 3,
            },
            readinessProbe: {
              httpGet: {
                path: '/readyz',
                port: 8414,
                httpHeaders: [{ name: 'Host', value: 'atc.geoff.cloud' }],
              },
              periodSeconds: 10,
            },
            resources: { requests: { cpu: '50m', memory: '128Mi' }, limits: { memory: '256Mi' } },
            securityContext: {
              readOnlyRootFilesystem: true,
              allowPrivilegeEscalation: false,
              capabilities: { drop: ['ALL'] },
            },
          },
        ],
        volumes: [
          { name: 'state', persistentVolumeClaim: { claimName: claim } },
          { name: 'config', emptyDir: {} },
          { name: 'runtime', emptyDir: { medium: 'Memory' } },
          { name: 'tmp', emptyDir: {} },
          { name: 'registry', configMap: { name: registry } },
        ],
      },
    },
  });
});

test("#buildATCGatewaySpec sends the public URL's host, port included, as the probes' Host header", () => {
  const claim = output('atc-gateway-state');
  const tokens = output('atc-gateway-daemon-tokens-0a1b2c3d');
  const registry = output('atc-gateway-registry-4e5f6a7b');

  expect(
    buildATCGatewaySpec({
      config: buildMockATCGatewayConfig({
        image:
          'ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000',
        publicURL: 'https://atc.geoff.cloud:8443',
      }),
      claim,
      tokens,
      registry,
    }),
  ).toStrictEqual({
    replicas: 1,
    strategy: { type: 'Recreate' },
    selector: { matchLabels: { app: 'atc-gateway' } },
    template: {
      metadata: { labels: { app: 'atc-gateway' } },
      spec: {
        securityContext: {
          runAsNonRoot: true,
          runAsUser: 65_532,
          runAsGroup: 65_532,
          fsGroup: 65_532,
          seccompProfile: { type: 'RuntimeDefault' },
        },
        automountServiceAccountToken: false,
        containers: [
          {
            name: 'atc-gateway',
            image:
              'ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000',
            args: [
              'serve',
              '--host',
              '0.0.0.0',
              '--port',
              '8414',
              '--public-url',
              'https://atc.geoff.cloud:8443',
              '--registry',
              '/etc/atc-gateway/registry.json',
              '--state-dir',
              '/home/nonroot/.local/state/atc',
            ],
            ports: [{ name: 'http', containerPort: 8414 }],
            envFrom: [{ secretRef: { name: tokens } }],
            env: [{ name: 'ATC_GATEWAY_STATE_DIR', value: '/home/nonroot/.local/state/atc' }],
            volumeMounts: [
              { name: 'state', mountPath: '/home/nonroot/.local/state/atc' },
              { name: 'config', mountPath: '/home/nonroot/.config' },
              { name: 'runtime', mountPath: '/run/atc' },
              { name: 'tmp', mountPath: '/tmp' },
              { name: 'registry', mountPath: '/etc/atc-gateway', readOnly: true },
            ],
            livenessProbe: {
              httpGet: {
                path: '/healthz',
                port: 8414,
                httpHeaders: [{ name: 'Host', value: 'atc.geoff.cloud:8443' }],
              },
              periodSeconds: 20,
              failureThreshold: 3,
            },
            readinessProbe: {
              httpGet: {
                path: '/readyz',
                port: 8414,
                httpHeaders: [{ name: 'Host', value: 'atc.geoff.cloud:8443' }],
              },
              periodSeconds: 10,
            },
            resources: { requests: { cpu: '50m', memory: '128Mi' }, limits: { memory: '256Mi' } },
            securityContext: {
              readOnlyRootFilesystem: true,
              allowPrivilegeEscalation: false,
              capabilities: { drop: ['ALL'] },
            },
          },
        ],
        volumes: [
          { name: 'state', persistentVolumeClaim: { claimName: claim } },
          { name: 'config', emptyDir: {} },
          { name: 'runtime', emptyDir: { medium: 'Memory' } },
          { name: 'tmp', emptyDir: {} },
          { name: 'registry', configMap: { name: registry } },
        ],
      },
    },
  });
});

test('#buildATCPodSecurity runs the pod as the nonroot user and group under the runtime seccomp profile', () => {
  expect(buildATCPodSecurity()).toStrictEqual({
    runAsNonRoot: true,
    runAsUser: 65_532,
    runAsGroup: 65_532,
    fsGroup: 65_532,
    seccompProfile: { type: 'RuntimeDefault' },
  });
});
