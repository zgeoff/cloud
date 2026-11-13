import { expect, test } from 'bun:test';
import { output } from '@pulumi/pulumi';
import { buildBoxxySpec } from './build-boxxy-spec.ts';

// the boxxy image and the rules sidecar's git-sync image the spec names, by tag and digest
function setupTest(): { image: string; rulesSyncImage: string } {
  return {
    image:
      'ghcr.io/zgeoff/cloud-boxxy:0123456@sha256:4444444444444444444444444444444444444444444444444444444444444444',
    rulesSyncImage:
      'registry.k8s.io/git-sync/git-sync:v4.8.0@sha256:5555555555555555555555555555555555555555555555555555555555555555',
  };
}

test("it runs the boxxy server as one nonroot replica on a read-only root, with a retained 1 GiB volume, a 16 MiB memory-backed /tmp, its configuration file, both tokens from its Secret, and the rules sidecar's checkout read-only at /rules", () => {
  const images = setupTest();
  const serviceName = output('boxxy');
  const configMap = output('boxxy-config-0a1b2c3d');
  const tokenSecret = output('boxxy-tokens-0a1b2c3d');

  expect(
    buildBoxxySpec({
      ...images,
      serviceName,
      configMap,
      tokenSecret,
      pepysSigningSecret: false,
      githubApp: false,
      reviewApp: false,
      noticeToken: false,
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
          { name: 'rules-sync-tmp', emptyDir: { medium: 'Memory', sizeLimit: '4Mi' } },
          { name: 'tmp', emptyDir: { medium: 'Memory', sizeLimit: '16Mi' } },
        ],
        initContainers: [
          {
            name: 'rules-sync',
            image: images.rulesSyncImage,
            restartPolicy: 'Always',
            args: [
              '--repo=https://github.com/zgeoff/boxxy-rules.git',
              '--ref=main',
              '--root=/git/root',
              '--link=current',
              '--period=30s',
              '--depth=1',
              '--max-failures=-1',
              '--stale-worktree-timeout=10m',
              '--http-bind=:2020',
              '--http-metrics',
            ],
            ports: [{ name: 'rules-sync', containerPort: 2020 }],
            startupProbe: {
              exec: { command: ['test', '-d', '/git/root/current'] },
              periodSeconds: 2,
              failureThreshold: 150,
            },
            volumeMounts: [
              { name: 'data', subPath: 'rules', mountPath: '/git' },
              { name: 'rules-sync-tmp', mountPath: '/tmp' },
            ],
            securityContext: {
              allowPrivilegeEscalation: false,
              readOnlyRootFilesystem: true,
              capabilities: { drop: ['ALL'] },
              runAsUser: 65_533,
              runAsGroup: 65_533,
            },
            resources: {
              requests: { cpu: '10m', memory: '16Mi' },
              limits: { memory: '64Mi' },
            },
          },
        ],
        containers: [
          {
            name: 'boxxy',
            image: images.image,
            ports: [
              { name: 'owner', containerPort: 8090 },
              { name: 'worker', containerPort: 8091 },
            ],
            env: [
              { name: 'BOXXY_CONFIG', value: '/etc/boxxy/config.json' },
              { name: 'GIT_CONFIG_COUNT', value: '1' },
              { name: 'GIT_CONFIG_KEY_0', value: 'safe.directory' },
              { name: 'GIT_CONFIG_VALUE_0', value: '*' },
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
              { name: 'data', subPath: 'rules', mountPath: '/rules', readOnly: true },
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
  const images = setupTest();
  const configMap = output('boxxy-issuers-0a1b2c3d');

  const spec = buildBoxxySpec({
    ...images,
    serviceName: output('boxxy'),
    configMap: output('boxxy-config-0a1b2c3d'),
    trustDocuments: { configMap, files: ['geoffcloud.json', 'other-host.json'] },
    tokenSecret: output('boxxy-tokens-0a1b2c3d'),
    pepysSigningSecret: false,
    githubApp: false,
    reviewApp: false,
    noticeToken: false,
    pullSecret: 'ghcr-pull',
  });

  expect(spec.template).toMatchObject({
    spec: {
      volumes: [
        { name: 'config', configMap: { name: expect.toBeObject() } },
        { name: 'rules-sync-tmp' },
        { name: 'tmp', emptyDir: { medium: 'Memory', sizeLimit: '16Mi' } },
        { name: 'issuers', configMap: { name: configMap } },
      ],
      containers: [
        {
          volumeMounts: [
            { name: 'data', mountPath: '/data' },
            { name: 'config', mountPath: '/etc/boxxy', readOnly: true },
            { name: 'tmp', mountPath: '/tmp' },
            { name: 'data', subPath: 'rules', mountPath: '/rules', readOnly: true },
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

test('it reads the pepys signing secret from the Secret when the config has a pepys section', () => {
  const tokenSecret = output('boxxy-tokens-0a1b2c3d');

  const spec = buildBoxxySpec({
    ...setupTest(),
    serviceName: output('boxxy'),
    configMap: output('boxxy-config-0a1b2c3d'),
    tokenSecret,
    pepysSigningSecret: true,
    githubApp: false,
    reviewApp: false,
    noticeToken: false,
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
          ]),
        },
      ],
    },
  });
});

test("it runs the door tunnel's connector beside the server, with the tunnel's token mounted in it alone, when the door has a tunnel", () => {
  const doorTunnelToken = output('boxxy-door-tunnel-token-0a1b2c3d');

  const spec = buildBoxxySpec({
    ...setupTest(),
    serviceName: output('boxxy'),
    configMap: output('boxxy-config-0a1b2c3d'),
    tokenSecret: output('boxxy-tokens-0a1b2c3d'),
    pepysSigningSecret: false,
    githubApp: false,
    reviewApp: false,
    noticeToken: false,
    pullSecret: 'ghcr-pull',
    doorTunnelToken,
  });

  expect(spec.template).toMatchObject({
    spec: {
      volumes: [
        { name: 'config' },
        { name: 'rules-sync-tmp' },
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
            { name: 'data', subPath: 'rules', mountPath: '/rules', readOnly: true },
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
    ...setupTest(),
    serviceName: output('boxxy'),
    configMap: output('boxxy-config-0a1b2c3d'),
    tokenSecret: output('boxxy-tokens-0a1b2c3d'),
    pepysSigningSecret: false,
    githubApp: false,
    reviewApp: false,
    noticeToken: false,
    pullSecret: 'ghcr-pull',
  });

  expect(spec.template).toMatchObject({
    spec: {
      containers: [{ name: 'boxxy' }],
      volumes: [{ name: 'config' }, { name: 'rules-sync-tmp' }, { name: 'tmp' }],
    },
  });
});

test("it reads each of the noslop App's keys from the Secret when the server runs its review gate", () => {
  const tokenSecret = output('boxxy-tokens-0a1b2c3d');

  const spec = buildBoxxySpec({
    ...setupTest(),
    serviceName: output('boxxy'),
    configMap: output('boxxy-config-0a1b2c3d'),
    tokenSecret,
    pepysSigningSecret: false,
    githubApp: false,
    reviewApp: true,
    noticeToken: false,
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

test('it reads the notice token alone from the Secret when the server sends notices', () => {
  const tokenSecret = output('boxxy-tokens-0a1b2c3d');

  const spec = buildBoxxySpec({
    ...setupTest(),
    serviceName: output('boxxy'),
    configMap: output('boxxy-config-0a1b2c3d'),
    tokenSecret,
    pepysSigningSecret: false,
    githubApp: false,
    reviewApp: false,
    noticeToken: true,
    pullSecret: 'ghcr-pull',
  });

  expect(spec.template).toMatchObject({
    spec: {
      containers: [
        {
          env: expect.arrayContaining([
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

test('it mounts no Secret for the rules repository, the checkout read-write in the sidecar alone, and read-only in the server', () => {
  const spec = buildBoxxySpec({
    ...setupTest(),
    serviceName: output('boxxy'),
    configMap: output('boxxy-config-0a1b2c3d'),
    tokenSecret: output('boxxy-tokens-0a1b2c3d'),
    pepysSigningSecret: false,
    githubApp: false,
    reviewApp: false,
    noticeToken: false,
    pullSecret: 'ghcr-pull',
  });

  expect(spec.template).toMatchObject({
    spec: {
      initContainers: [
        {
          name: 'rules-sync',
          volumeMounts: [
            { name: 'data', subPath: 'rules', mountPath: '/git' },
            { name: 'rules-sync-tmp', mountPath: '/tmp' },
          ],
        },
      ],
      volumes: [{ name: 'config' }, { name: 'rules-sync-tmp' }, { name: 'tmp' }],
      containers: [
        {
          name: 'boxxy',
          volumeMounts: expect.arrayContaining([
            { name: 'data', subPath: 'rules', mountPath: '/rules', readOnly: true },
          ]),
        },
      ],
    },
  });
});

test("it reads each of the boxxy App's keys from the Secret when the server calls GitHub", () => {
  const tokenSecret = output('boxxy-tokens-0a1b2c3d');

  const spec = buildBoxxySpec({
    ...setupTest(),
    serviceName: output('boxxy'),
    configMap: output('boxxy-config-0a1b2c3d'),
    tokenSecret,
    pepysSigningSecret: false,
    githubApp: true,
    reviewApp: false,
    noticeToken: false,
    pullSecret: 'ghcr-pull',
  });

  expect(spec.template).toMatchObject({
    spec: {
      containers: [
        {
          env: expect.arrayContaining([
            {
              name: 'BOXXY_GITHUB_APP_CLIENT_ID',
              valueFrom: { secretKeyRef: { name: tokenSecret, key: 'boxxy-app-client-id' } },
            },
            {
              name: 'BOXXY_GITHUB_APP_PRIVATE_KEY',
              valueFrom: { secretKeyRef: { name: tokenSecret, key: 'boxxy-app-private-key' } },
            },
            {
              name: 'BOXXY_GITHUB_APP_INSTALLATION_ID',
              valueFrom: { secretKeyRef: { name: tokenSecret, key: 'boxxy-app-installation-id' } },
            },
          ]),
        },
      ],
    },
  });
});
