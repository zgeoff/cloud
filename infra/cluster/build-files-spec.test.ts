import { expect, test } from 'bun:test';
import { output } from '@pulumi/pulumi';
import { buildFilesSpec } from './build-files-spec.ts';

test('it runs the files service as one nonroot replica on a read-only root, with a retained 20 GiB volume and only the token hashes from its Secret', () => {
  const serviceName = output('files');
  const tokenSecret = output('files-tokens-0a1b2c3d');

  expect(
    buildFilesSpec({
      image:
        'ghcr.io/zgeoff/cloud-files:0123456@sha256:3333333333333333333333333333333333333333333333333333333333333333',
      publicURL: 'https://files.geoff.cloud',
      serviceName,
      tokenSecret,
      pullSecret: 'ghcr-pull',
    }),
  ).toStrictEqual({
    replicas: 1,
    updateStrategy: { type: 'RollingUpdate' },
    podManagementPolicy: 'Parallel',
    serviceName,
    selector: { matchLabels: { app: 'files' } },
    template: {
      metadata: { labels: { app: 'files' } },
      spec: {
        securityContext: {
          fsGroup: 65_532,
          runAsNonRoot: true,
          seccompProfile: { type: 'RuntimeDefault' },
        },
        automountServiceAccountToken: false,
        enableServiceLinks: false,
        imagePullSecrets: [{ name: 'ghcr-pull' }],
        volumes: [{ name: 'tmp', emptyDir: {} }],
        containers: [
          {
            name: 'files',
            image:
              'ghcr.io/zgeoff/cloud-files:0123456@sha256:3333333333333333333333333333333333333333333333333333333333333333',
            ports: [{ name: 'http', containerPort: 8080 }],
            env: [
              { name: 'FILES_PORT', value: '8080' },
              { name: 'FILES_DATA_DIR', value: '/data' },
              { name: 'FILES_PUBLIC_URL', value: 'https://files.geoff.cloud' },
              {
                name: 'FILES_AGENT_TOKEN_SHA256',
                valueFrom: { secretKeyRef: { name: tokenSecret, key: 'agent-token-sha256' } },
              },
              {
                name: 'FILES_OWNER_TOKEN_SHA256',
                valueFrom: { secretKeyRef: { name: tokenSecret, key: 'owner-token-sha256' } },
              },
            ],
            readinessProbe: {
              httpGet: { path: '/healthz', port: 8080 },
              periodSeconds: 10,
              failureThreshold: 3,
            },
            livenessProbe: {
              httpGet: { path: '/healthz', port: 8080 },
              periodSeconds: 30,
              failureThreshold: 3,
            },
            volumeMounts: [
              { name: 'data', mountPath: '/data' },
              { name: 'tmp', mountPath: '/tmp' },
            ],
            securityContext: {
              allowPrivilegeEscalation: false,
              readOnlyRootFilesystem: true,
              capabilities: { drop: ['ALL'] },
              runAsUser: 65_532,
              runAsGroup: 65_532,
            },
            resources: { requests: { cpu: '50m', memory: '64Mi' }, limits: { memory: '768Mi' } },
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
          resources: { requests: { storage: '20Gi' } },
        },
      },
    ],
  });
});
