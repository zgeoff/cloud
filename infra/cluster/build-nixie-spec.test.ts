import { expect, test } from 'bun:test';
import { output } from '@pulumi/pulumi';
import { buildNixieSpec } from './build-nixie-spec.ts';

test('it runs nixie as one replica that a rollout stops before it starts the next, even while it is unready, on a retained volume, with git-sync beside it holding the deploy key and nixie alone holding the age identity', () => {
  const serviceName = output('nixie');
  const configMap = output('nixie-config-0a1b2c3d');
  const secret = output('nixie-secrets-4e5f6a7b');
  const definitionsSecret = output('nixie-definitions-key-8c9d0e1f');

  expect(
    buildNixieSpec({
      image:
        'ghcr.io/zgeoff/nixie:0.1.0@sha256:06d8802f4aac382106d53be0915887e86e36c6960e2404e19af6611a4c01b309',
      serviceName,
      configMap,
      secret,
      definitionsSecret,
    }),
  ).toStrictEqual({
    replicas: 1,
    updateStrategy: { type: 'RollingUpdate' },
    podManagementPolicy: 'Parallel',
    serviceName,
    selector: { matchLabels: { app: 'nixie' } },
    template: {
      metadata: { labels: { app: 'nixie' } },
      spec: {
        terminationGracePeriodSeconds: 60,
        securityContext: {
          fsGroup: 10_001,
          runAsNonRoot: true,
          seccompProfile: { type: 'RuntimeDefault' },
        },
        volumes: [
          { name: 'config', configMap: { name: configMap } },
          { name: 'secrets', secret: { secretName: secret, defaultMode: 0o440 } },
          {
            name: 'definitions-key',
            secret: { secretName: definitionsSecret, defaultMode: 0o440 },
          },
          { name: 'definitions', emptyDir: {} },
          { name: 'tmp', emptyDir: {} },
          { name: 'git-sync-tmp', emptyDir: {} },
        ],
        containers: [
          {
            name: 'nixie',
            image:
              'ghcr.io/zgeoff/nixie:0.1.0@sha256:06d8802f4aac382106d53be0915887e86e36c6960e2404e19af6611a4c01b309',
            ports: [{ name: 'http', containerPort: 8080 }],
            env: [{ name: 'SOPS_AGE_KEY_FILE', value: '/etc/nixie/age/age-key.txt' }],
            startupProbe: {
              httpGet: { path: '/health/live', port: 8080 },
              periodSeconds: 5,
              failureThreshold: 60,
            },
            livenessProbe: {
              httpGet: { path: '/health/live', port: 8080 },
              periodSeconds: 30,
              failureThreshold: 3,
            },
            readinessProbe: { httpGet: { path: '/health/ready', port: 8080 }, periodSeconds: 10 },
            volumeMounts: [
              { name: 'data', mountPath: '/data' },
              {
                name: 'config',
                mountPath: '/etc/nixie/config.yaml',
                subPath: 'config.yaml',
                readOnly: true,
              },
              {
                name: 'secrets',
                mountPath: '/etc/nixie/secrets.yaml',
                subPath: 'secrets.yaml',
                readOnly: true,
              },
              {
                name: 'secrets',
                mountPath: '/etc/nixie/age/age-key.txt',
                subPath: 'age-key.txt',
                readOnly: true,
              },
              { name: 'definitions', mountPath: '/etc/nixie/definitions', readOnly: true },
              { name: 'tmp', mountPath: '/tmp' },
            ],
            securityContext: {
              allowPrivilegeEscalation: false,
              readOnlyRootFilesystem: true,
              capabilities: { drop: ['ALL'] },
              runAsUser: 10_001,
              runAsGroup: 10_001,
            },
            resources: { requests: { cpu: '100m', memory: '256Mi' }, limits: { memory: '1Gi' } },
          },
          {
            name: 'git-sync',
            image:
              'registry.k8s.io/git-sync/git-sync:v4.7.1@sha256:c5e1976da735bf0b53979f079a07475d77174c51863cd084e928ff6074480717',
            env: [
              {
                name: 'GITSYNC_REPO',
                value: 'ssh://git@ssh.github.com:443/zgeoff/nixie-definitions.git',
              },
              { name: 'GITSYNC_REF', value: 'main' },
              { name: 'GITSYNC_ROOT', value: '/etc/nixie/definitions' },
              { name: 'GITSYNC_LINK', value: 'current' },
              { name: 'GITSYNC_PERIOD', value: '60s' },
              { name: 'GITSYNC_DEPTH', value: '1' },
              { name: 'GITSYNC_SSH_KEY_FILE', value: '/etc/git-secret/ssh' },
              { name: 'GITSYNC_SSH_KNOWN_HOSTS', value: 'true' },
              { name: 'GITSYNC_SSH_KNOWN_HOSTS_FILE', value: '/etc/git-secret/known_hosts' },
            ],
            volumeMounts: [
              { name: 'definitions', mountPath: '/etc/nixie/definitions' },
              { name: 'definitions-key', mountPath: '/etc/git-secret', readOnly: true },
              { name: 'git-sync-tmp', mountPath: '/tmp' },
            ],
            securityContext: {
              allowPrivilegeEscalation: false,
              readOnlyRootFilesystem: true,
              capabilities: { drop: ['ALL'] },
              runAsUser: 65_533,
              runAsGroup: 65_533,
            },
            resources: { requests: { cpu: '10m', memory: '32Mi' }, limits: { memory: '128Mi' } },
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
          resources: { requests: { storage: '10Gi' } },
        },
      },
    ],
  });
});
