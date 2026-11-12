import { expect, test } from 'bun:test';
import { output } from '@pulumi/pulumi';
import invariant from 'tiny-invariant';
import { buildMockATCGatewayConfig } from '../test-utils/build-mock-atc-gateway-config.ts';
import { buildMockATCGatewaySpecInputs } from '../test-utils/build-mock-atc-gateway-spec-inputs.ts';
import { buildATCGatewaySpec, buildATCPodSecurity } from './build-atc-gateway-spec.ts';

test("#buildATCGatewaySpec keeps state in $HOME's state dir and trusts no proxy when the config sets no stateDir or trustForwardedFrom, passing the claim, tokens, registry and pull Secret through and the tunnel's token to the cloudflared sidecar alone", () => {
  const claim = output('atc-gateway-state');
  const tokens = output('atc-gateway-daemon-tokens-0a1b2c3d');
  const registry = output('atc-gateway-registry-4e5f6a7b');
  const pullSecret = output('ghcr-pull');
  const tunnelToken = output('atc-tunnel-token-8c9d0e1f');

  expect(
    buildATCGatewaySpec({
      config: buildMockATCGatewayConfig({
        image:
          'ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000',
        publicURL: 'https://atc.geoff.cloud',
        stateDir: undefined,
        trustForwardedFrom: undefined,
      }),
      publicHost: 'atc.geoff.cloud',
      claim,
      tokens,
      registry,
      pullSecret,
      tunnelToken,
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
        imagePullSecrets: [{ name: pullSecret }],
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
          {
            name: 'cloudflared',
            image: 'cloudflare/cloudflared:2026.9.3',
            args: [
              'tunnel',
              '--no-autoupdate',
              '--metrics',
              '127.0.0.1:2000',
              'run',
              '--token-file',
              '/etc/cloudflared/token',
            ],
            volumeMounts: [{ name: 'tunnel-token', mountPath: '/etc/cloudflared', readOnly: true }],
            resources: {
              requests: { cpu: '10m', memory: '32Mi' },
              limits: { cpu: '200m', memory: '128Mi' },
            },
            securityContext: {
              runAsNonRoot: true,
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
          { name: 'tunnel-token', secret: { secretName: tunnelToken, defaultMode: 0o440 } },
        ],
      },
    },
  });
});

test('#buildATCGatewaySpec mounts the state volume at the stateDir the config sets and points the gateway at it', () => {
  const claim = output('atc-gateway-state');
  const tokens = output('atc-gateway-daemon-tokens-0a1b2c3d');
  const registry = output('atc-gateway-registry-4e5f6a7b');
  const pullSecret = output('ghcr-pull');
  const tunnelToken = output('atc-tunnel-token-8c9d0e1f');

  expect(
    buildATCGatewaySpec({
      config: buildMockATCGatewayConfig({
        image:
          'ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000',
        publicURL: 'https://atc.geoff.cloud',
        stateDir: '/var/lib/atc-gateway',
        trustForwardedFrom: undefined,
      }),
      publicHost: 'atc.geoff.cloud',
      claim,
      tokens,
      registry,
      pullSecret,
      tunnelToken,
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
        imagePullSecrets: [{ name: pullSecret }],
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
          {
            name: 'cloudflared',
            image: 'cloudflare/cloudflared:2026.9.3',
            args: [
              'tunnel',
              '--no-autoupdate',
              '--metrics',
              '127.0.0.1:2000',
              'run',
              '--token-file',
              '/etc/cloudflared/token',
            ],
            volumeMounts: [{ name: 'tunnel-token', mountPath: '/etc/cloudflared', readOnly: true }],
            resources: {
              requests: { cpu: '10m', memory: '32Mi' },
              limits: { cpu: '200m', memory: '128Mi' },
            },
            securityContext: {
              runAsNonRoot: true,
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
          { name: 'tunnel-token', secret: { secretName: tunnelToken, defaultMode: 0o440 } },
        ],
      },
    },
  });
});

test("#buildATCGatewaySpec sends the public host it is given, port included, as the probes' Host header", () => {
  const claim = output('atc-gateway-state');
  const tokens = output('atc-gateway-daemon-tokens-0a1b2c3d');
  const registry = output('atc-gateway-registry-4e5f6a7b');
  const pullSecret = output('ghcr-pull');
  const tunnelToken = output('atc-tunnel-token-8c9d0e1f');

  expect(
    buildATCGatewaySpec({
      config: buildMockATCGatewayConfig({
        image:
          'ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000',
        publicURL: 'https://atc.geoff.cloud:8443',
        stateDir: undefined,
        trustForwardedFrom: undefined,
      }),
      publicHost: 'atc.geoff.cloud:8443',
      claim,
      tokens,
      registry,
      pullSecret,
      tunnelToken,
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
        imagePullSecrets: [{ name: pullSecret }],
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
          {
            name: 'cloudflared',
            image: 'cloudflare/cloudflared:2026.9.3',
            args: [
              'tunnel',
              '--no-autoupdate',
              '--metrics',
              '127.0.0.1:2000',
              'run',
              '--token-file',
              '/etc/cloudflared/token',
            ],
            volumeMounts: [{ name: 'tunnel-token', mountPath: '/etc/cloudflared', readOnly: true }],
            resources: {
              requests: { cpu: '10m', memory: '32Mi' },
              limits: { cpu: '200m', memory: '128Mi' },
            },
            securityContext: {
              runAsNonRoot: true,
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
          { name: 'tunnel-token', secret: { secretName: tunnelToken, defaultMode: 0o440 } },
        ],
      },
    },
  });
});

test.each([
  ['no flag for an empty list', [], []],
  [
    'one flag per address, in order',
    ['127.0.0.1', '::1'],
    ['--trust-forwarded-from', '127.0.0.1', '--trust-forwarded-from', '::1'],
  ],
])(
  '#buildATCGatewaySpec passes the trusted proxies to the gateway as %s',
  (_kind, trustForwardedFrom, flags) => {
    const claim = output('atc-gateway-state');
    const tokens = output('atc-gateway-daemon-tokens-0a1b2c3d');
    const registry = output('atc-gateway-registry-4e5f6a7b');
    const pullSecret = output('ghcr-pull');
    const tunnelToken = output('atc-tunnel-token-8c9d0e1f');

    expect(
      buildATCGatewaySpec({
        config: buildMockATCGatewayConfig({
          image:
            'ghcr.io/zgeoff/atc-gateway:3.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000',
          publicURL: 'https://atc.geoff.cloud',
          stateDir: '/var/lib/atc-gateway',
          trustForwardedFrom,
        }),
        publicHost: 'atc.geoff.cloud',
        claim,
        tokens,
        registry,
        pullSecret,
        tunnelToken,
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
          imagePullSecrets: [{ name: pullSecret }],
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
                ...flags,
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
            {
              name: 'cloudflared',
              image: 'cloudflare/cloudflared:2026.9.3',
              args: [
                'tunnel',
                '--no-autoupdate',
                '--metrics',
                '127.0.0.1:2000',
                'run',
                '--token-file',
                '/etc/cloudflared/token',
              ],
              volumeMounts: [
                { name: 'tunnel-token', mountPath: '/etc/cloudflared', readOnly: true },
              ],
              resources: {
                requests: { cpu: '10m', memory: '32Mi' },
                limits: { cpu: '200m', memory: '128Mi' },
              },
              securityContext: {
                runAsNonRoot: true,
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
            { name: 'tunnel-token', secret: { secretName: tunnelToken, defaultMode: 0o440 } },
          ],
        },
      },
    });
  },
);

test('#buildATCPodSecurity runs the pod as the nonroot user and group under the runtime seccomp profile', () => {
  expect(buildATCPodSecurity()).toStrictEqual({
    runAsNonRoot: true,
    runAsUser: 65_532,
    runAsGroup: 65_532,
    fsGroup: 65_532,
    seccompProfile: { type: 'RuntimeDefault' },
  });
});

test('#buildATCGatewaySpec adds no init container, volume, mount or flag without a service token Secret', () => {
  const spec = buildATCGatewaySpec(buildMockATCGatewaySpecInputs());
  const text = JSON.stringify(spec);

  expect(spec.template.spec).not.toHaveProperty('initContainers');
  expect(text).not.toContain('service-token');
  expect(text).not.toContain('atcs_');
  expect(spec.template.spec.volumes).toHaveLength(6);
  expect(spec.template.spec.containers[0]?.volumeMounts).toHaveLength(5);
});

test('#buildATCGatewaySpec changes nothing else when it adds the service token Secret', () => {
  const inputs = buildMockATCGatewaySpecInputs();
  const without = buildATCGatewaySpec(inputs);

  const withToken = buildATCGatewaySpec({
    ...inputs,
    serviceTokens: output('atc-gateway-service-tokens-2b3c4d5e'),
  });

  const [gateway, tunnel] = withToken.template.spec.containers;
  const [baseGateway, baseTunnel] = without.template.spec.containers;

  invariant(gateway !== undefined && baseGateway !== undefined, 'expected the gateway container');

  // the tunnel sidecar and the gateway's other fields stay as they were
  expect(tunnel).toStrictEqual(baseTunnel);

  expect({ ...gateway, args: [], volumeMounts: [] }).toStrictEqual({
    ...baseGateway,
    args: [],
    volumeMounts: [],
  });

  expect(gateway.args.slice(0, -2)).toStrictEqual(baseGateway.args);
  expect(gateway.volumeMounts.slice(0, -1)).toStrictEqual(baseGateway.volumeMounts);
  expect(withToken.template.spec.volumes.slice(0, 6)).toStrictEqual(without.template.spec.volumes);

  expect({
    ...withToken.template.spec,
    initContainers: undefined,
    containers: undefined,
    volumes: undefined,
  }).toStrictEqual({
    ...without.template.spec,
    initContainers: undefined,
    containers: undefined,
    volumes: undefined,
  });
});

test("#buildATCGatewaySpec passes --service-token-file, mounts the gateway user's own copy of the file read-only, and copies it with the gateway's user in an init container", () => {
  const serviceTokens = output('atc-gateway-service-tokens-2b3c4d5e');
  const spec = buildATCGatewaySpec({ ...buildMockATCGatewaySpecInputs(), serviceTokens });
  const [gateway] = spec.template.spec.containers;

  invariant(gateway !== undefined, 'expected the gateway container');

  expect(gateway.args.slice(-2)).toStrictEqual([
    '--service-token-file',
    '/etc/atc-gateway-service-tokens/service-tokens.json',
  ]);

  expect(gateway.volumeMounts.at(-1)).toStrictEqual({
    name: 'service-token',
    mountPath: '/etc/atc-gateway-service-tokens',
    readOnly: true,
  });

  expect(spec.template.spec.volumes?.slice(6)).toStrictEqual([
    { name: 'service-token-source', secret: { secretName: serviceTokens, defaultMode: 0o440 } },
    { name: 'service-token', emptyDir: { medium: 'Memory', sizeLimit: '1Mi' } },
  ]);

  expect(spec.template.spec.initContainers).toStrictEqual([
    {
      name: 'service-token',
      image:
        'ghcr.io/zgeoff/atc-gateway-backup:2.24.0-r2@sha256:1111111111111111111111111111111111111111111111111111111111111111',
      command: [
        'sh',
        '-c',
        'umask 077 && cat /service-token-source/service-tokens.json > /service-token/service-tokens.json',
      ],
      volumeMounts: [
        { name: 'service-token-source', mountPath: '/service-token-source', readOnly: true },
        { name: 'service-token', mountPath: '/service-token' },
      ],
      resources: { requests: { cpu: '10m', memory: '16Mi' }, limits: { memory: '32Mi' } },
      securityContext: {
        runAsNonRoot: true,
        readOnlyRootFilesystem: true,
        allowPrivilegeEscalation: false,
        capabilities: { drop: ['ALL'] },
      },
    },
  ]);
});
