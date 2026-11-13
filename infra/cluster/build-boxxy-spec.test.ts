import { expect, test } from 'bun:test';
import { output } from '@pulumi/pulumi';
import { buildBoxxySpec } from './build-boxxy-spec.ts';

// the boxxy image the spec names, by tag and digest
function setupTest(): string {
  return 'ghcr.io/zgeoff/cloud-boxxy:0123456@sha256:4444444444444444444444444444444444444444444444444444444444444444';
}

test('it runs the boxxy server as one nonroot replica on a read-only root, with a retained 1 GiB volume, a 16 MiB memory-backed /tmp, its configuration file and both tokens from its Secret', () => {
  const image = setupTest();
  const serviceName = output('boxxy');
  const configMap = output('boxxy-config-0a1b2c3d');
  const tokenSecret = output('boxxy-tokens-0a1b2c3d');

  expect(
    buildBoxxySpec({
      image,
      serviceName,
      configMap,
      tokenSecret,
      pepysSigningSecret: false,
      githubToken: false,
      reviewApp: false,
      notice: false,
      pullSecret: 'ghcr-pull',
    }),
  ).toStrictEqual({
    replicas: 1,
    updateStrategy: { type: 'RollingUpdate' },
    podManagementPolicy: 'Parallel',
    serviceName,
    selector: { matchLabels: { app: 'boxxy-server' } },
    template: {
      metadata: { labels: { app: 'boxxy-server' } },
      spec: {
        securityContext: {
          fsGroup: 65_532,
          runAsNonRoot: true,
          seccompProfile: { type: 'RuntimeDefault' },
        },
        automountServiceAccountToken: false,
        enableServiceLinks: false,
        imagePullSecrets: [{ name: 'ghcr-pull' }],
        volumes: [
          { name: 'config', configMap: { name: configMap } },
          { name: 'tmp', emptyDir: { medium: 'Memory', sizeLimit: '16Mi' } },
        ],
        containers: [
          {
            name: 'boxxy',
            image,
            ports: [
              { name: 'owner', containerPort: 8090 },
              { name: 'worker', containerPort: 8091 },
            ],
            env: [
              { name: 'BOXXY_CONFIG', value: '/etc/boxxy/config.json' },
              {
                name: 'BOXXY_WORKER_TOKEN',
                valueFrom: {
                  secretKeyRef: { name: tokenSecret, key: 'worker-token' },
                },
              },
              {
                name: 'BOXXY_ATC_TOKEN',
                valueFrom: {
                  secretKeyRef: { name: tokenSecret, key: 'atc-token' },
                },
              },
            ],
            readinessProbe: {
              httpGet: { path: '/healthz', port: 8090 },
              periodSeconds: 10,
              failureThreshold: 3,
            },
            livenessProbe: {
              httpGet: { path: '/healthz', port: 8090 },
              periodSeconds: 30,
              failureThreshold: 3,
            },
            volumeMounts: [
              { name: 'data', mountPath: '/data' },
              { name: 'config', mountPath: '/etc/boxxy', readOnly: true },
              { name: 'tmp', mountPath: '/tmp' },
            ],
            securityContext: {
              allowPrivilegeEscalation: false,
              readOnlyRootFilesystem: true,
              capabilities: { drop: ['ALL'] },
              runAsUser: 65_532,
              runAsGroup: 65_532,
            },
            resources: {
              requests: { cpu: '50m', memory: '128Mi' },
              limits: { memory: '256Mi' },
            },
          },
        ],
      },
    },
    volumeClaimTemplates: [
      {
        metadata: { name: 'data' },
        spec: {
          accessModes: ['ReadWriteOnce'],
          storageClassName: 'local-path-retain',
          resources: { requests: { storage: '1Gi' } },
        },
      },
    ],
  });
});

test('it mounts each trust document read-only as a regular file in the issuers folder when a ConfigMap holds them', () => {
  const image = setupTest();
  const configMap = output('boxxy-issuers-0a1b2c3d');

  const spec = buildBoxxySpec({
    image,
    serviceName: output('boxxy'),
    configMap: output('boxxy-config-0a1b2c3d'),
    trustDocuments: { configMap, files: ['geoffcloud.json', 'other-host.json'] },
    tokenSecret: output('boxxy-tokens-0a1b2c3d'),
    pepysSigningSecret: false,
    githubToken: false,
    reviewApp: false,
    notice: false,
    pullSecret: 'ghcr-pull',
  });

  expect(spec.template).toMatchObject({
    spec: {
      volumes: [
        { name: 'config', configMap: { name: expect.toBeObject() } },
        { name: 'tmp', emptyDir: { medium: 'Memory', sizeLimit: '16Mi' } },
        { name: 'issuers', configMap: { name: configMap } },
      ],
      containers: [
        {
          volumeMounts: [
            { name: 'data', mountPath: '/data' },
            { name: 'config', mountPath: '/etc/boxxy', readOnly: true },
            { name: 'tmp', mountPath: '/tmp' },
            {
              name: 'issuers',
              mountPath: '/etc/boxxy-issuers/geoffcloud.json',
              subPath: 'geoffcloud.json',
              readOnly: true,
            },
            {
              name: 'issuers',
              mountPath: '/etc/boxxy-issuers/other-host.json',
              subPath: 'other-host.json',
              readOnly: true,
            },
          ],
        },
      ],
    },
  });
});

test('it reads the pepys signing secret and the GitHub token from the Secret when the config needs them', () => {
  const tokenSecret = output('boxxy-tokens-0a1b2c3d');

  const spec = buildBoxxySpec({
    image: setupTest(),
    serviceName: output('boxxy'),
    configMap: output('boxxy-config-0a1b2c3d'),
    tokenSecret,
    pepysSigningSecret: true,
    githubToken: true,
    reviewApp: false,
    notice: false,
    pullSecret: 'ghcr-pull',
  });

  expect(spec.template).toMatchObject({
    spec: {
      containers: [
        {
          env: expect.arrayContaining([
            {
              name: 'BOXXY_PEPYS_SIGNING_SECRET',
              valueFrom: { secretKeyRef: { name: tokenSecret, key: 'pepys-signing-secret' } },
            },
            {
              name: 'BOXXY_GITHUB_TOKEN',
              valueFrom: { secretKeyRef: { name: tokenSecret, key: 'github-token' } },
            },
          ]),
        },
      ],
    },
  });
});

test("it runs the door tunnel's connector beside the server, with the tunnel's token mounted in it alone, when the door has a tunnel", () => {
  const doorTunnelToken = output('boxxy-door-tunnel-token-0a1b2c3d');

  const spec = buildBoxxySpec({
    image: setupTest(),
    serviceName: output('boxxy'),
    configMap: output('boxxy-config-0a1b2c3d'),
    tokenSecret: output('boxxy-tokens-0a1b2c3d'),
    pepysSigningSecret: false,
    githubToken: false,
    reviewApp: false,
    notice: false,
    pullSecret: 'ghcr-pull',
    doorTunnelToken,
  });

  expect(spec.template).toMatchObject({
    spec: {
      volumes: [
        { name: 'config' },
        { name: 'tmp' },
        { name: 'tunnel-token', secret: { secretName: doorTunnelToken, defaultMode: 0o440 } },
      ],
      containers: [
        {
          name: 'boxxy',
          volumeMounts: [
            { name: 'data', mountPath: '/data' },
            { name: 'config', mountPath: '/etc/boxxy', readOnly: true },
            { name: 'tmp', mountPath: '/tmp' },
          ],
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
    },
  });
});

test('it runs no connector and mounts no tunnel token without a door tunnel', () => {
  const spec = buildBoxxySpec({
    image: setupTest(),
    serviceName: output('boxxy'),
    configMap: output('boxxy-config-0a1b2c3d'),
    tokenSecret: output('boxxy-tokens-0a1b2c3d'),
    pepysSigningSecret: false,
    githubToken: false,
    reviewApp: false,
    notice: false,
    pullSecret: 'ghcr-pull',
  });

  expect(spec.template).toMatchObject({
    spec: { containers: [{ name: 'boxxy' }], volumes: [{ name: 'config' }, { name: 'tmp' }] },
  });
});

test("it reads each of the noslop App's keys from the Secret when the server runs its review gate", () => {
  const tokenSecret = output('boxxy-tokens-0a1b2c3d');

  const spec = buildBoxxySpec({
    image: setupTest(),
    serviceName: output('boxxy'),
    configMap: output('boxxy-config-0a1b2c3d'),
    tokenSecret,
    pepysSigningSecret: false,
    githubToken: true,
    reviewApp: true,
    notice: false,
    pullSecret: 'ghcr-pull',
  });

  expect(spec.template).toMatchObject({
    spec: {
      containers: [
        {
          env: expect.arrayContaining([
            {
              name: 'NOSLOP_GITHUB_APP_ID',
              valueFrom: { secretKeyRef: { name: tokenSecret, key: 'noslop-app-id' } },
            },
            {
              name: 'NOSLOP_GITHUB_APP_PRIVATE_KEY',
              valueFrom: { secretKeyRef: { name: tokenSecret, key: 'noslop-app-private-key' } },
            },
            {
              name: 'NOSLOP_GITHUB_APP_INSTALLATION_ID',
              valueFrom: { secretKeyRef: { name: tokenSecret, key: 'noslop-app-installation-id' } },
            },
          ]),
        },
      ],
    },
  });
});

test('it reads the notice session and the notice token from the Secret when the server sends notices', () => {
  const tokenSecret = output('boxxy-tokens-0a1b2c3d');

  const spec = buildBoxxySpec({
    image: setupTest(),
    serviceName: output('boxxy'),
    configMap: output('boxxy-config-0a1b2c3d'),
    tokenSecret,
    pepysSigningSecret: false,
    githubToken: false,
    reviewApp: false,
    notice: true,
    pullSecret: 'ghcr-pull',
  });

  expect(spec.template).toMatchObject({
    spec: {
      containers: [
        {
          env: expect.arrayContaining([
            {
              name: 'BOXXY_ATC_NOTICE_SESSION',
              valueFrom: { secretKeyRef: { name: tokenSecret, key: 'atc-notice-session' } },
            },
            {
              name: 'BOXXY_ATC_NOTICE_TOKEN',
              valueFrom: { secretKeyRef: { name: tokenSecret, key: 'atc-notice-token' } },
            },
          ]),
        },
      ],
    },
  });
});
