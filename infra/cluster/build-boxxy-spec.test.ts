import { expect, test } from 'bun:test';
import { output } from '@pulumi/pulumi';
import { buildBoxxySpec } from './build-boxxy-spec.ts';

// the boxxy image the spec names, by tag and digest
function setupTest(): string {
  return 'ghcr.io/zgeoff/cloud-boxxy:0123456@sha256:4444444444444444444444444444444444444444444444444444444444444444';
}

test('it runs the boxxy server as one nonroot replica on a read-only root, with a retained 1 GiB volume, its configuration file and both tokens from its Secret', () => {
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
        volumes: [{ name: 'config', configMap: { name: configMap } }],
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
    pullSecret: 'ghcr-pull',
  });

  expect(spec.template).toMatchObject({
    spec: {
      volumes: [
        { name: 'config', configMap: { name: expect.toBeObject() } },
        { name: 'issuers', configMap: { name: configMap } },
      ],
      containers: [
        {
          volumeMounts: [
            { name: 'data', mountPath: '/data' },
            { name: 'config', mountPath: '/etc/boxxy', readOnly: true },
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
