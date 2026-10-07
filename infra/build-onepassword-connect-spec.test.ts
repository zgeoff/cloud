// the test asserts the whole spec as one literal, so its body is long
/* oxlint-disable max-lines-per-function */
import { expect, test } from 'bun:test';
import { output } from '@pulumi/pulumi';
import { buildOnePasswordConnectSpec } from './build-onepassword-connect-spec.ts';

test("it runs connect-api and connect-sync in one pod, each bus port the other's peer, both reading the credentials file from the Secret", () => {
  const credentialsSecret = output('onepassword-connect-credentials-0a1b2c3d');

  expect(buildOnePasswordConnectSpec(credentialsSecret)).toStrictEqual({
    replicas: 1,
    selector: { matchLabels: { app: 'onepassword-connect' } },
    template: {
      metadata: { labels: { app: 'onepassword-connect' } },
      spec: {
        securityContext: {
          fsGroup: 999,
          runAsUser: 999,
          runAsGroup: 999,
          runAsNonRoot: true,
          seccompProfile: { type: 'RuntimeDefault' },
        },
        volumes: [
          { name: 'shared-data', emptyDir: {} },
          { name: 'credentials', secret: { secretName: credentialsSecret } },
        ],
        containers: [
          {
            name: 'connect-api',
            image: '1password/connect-api:1.8.3',
            env: [
              { name: 'OP_HTTP_PORT', value: '8080' },
              { name: 'OP_SESSION', value: '/home/opuser/.op/1password-credentials.json' },
              { name: 'OP_BUS_PORT', value: '11220' },
              { name: 'OP_BUS_PEERS', value: 'localhost:11221' },
              { name: 'OP_LOG_LEVEL', value: 'info' },
            ],
            readinessProbe: { httpGet: { path: '/health', port: 8080 } },
            livenessProbe: {
              httpGet: { path: '/heartbeat', port: 8080 },
              periodSeconds: 30,
              failureThreshold: 3,
              initialDelaySeconds: 15,
            },
            volumeMounts: [
              { name: 'shared-data', mountPath: '/home/opuser/.op/data' },
              {
                name: 'credentials',
                mountPath: '/home/opuser/.op/1password-credentials.json',
                subPath: '1password-credentials.json',
                readOnly: true,
              },
            ],
            securityContext: {
              allowPrivilegeEscalation: false,
              readOnlyRootFilesystem: true,
              capabilities: { drop: ['ALL'] },
            },
            resources: { requests: { cpu: '10m', memory: '32Mi' }, limits: { memory: '128Mi' } },
          },
          {
            name: 'connect-sync',
            image: '1password/connect-sync:1.8.3',
            env: [
              { name: 'OP_HTTP_PORT', value: '8081' },
              { name: 'OP_SESSION', value: '/home/opuser/.op/1password-credentials.json' },
              { name: 'OP_BUS_PORT', value: '11221' },
              { name: 'OP_BUS_PEERS', value: 'localhost:11220' },
              { name: 'OP_LOG_LEVEL', value: 'info' },
            ],
            readinessProbe: { httpGet: { path: '/health', port: 8081 } },
            livenessProbe: {
              httpGet: { path: '/heartbeat', port: 8081 },
              periodSeconds: 30,
              failureThreshold: 3,
              initialDelaySeconds: 15,
            },
            volumeMounts: [
              { name: 'shared-data', mountPath: '/home/opuser/.op/data' },
              {
                name: 'credentials',
                mountPath: '/home/opuser/.op/1password-credentials.json',
                subPath: '1password-credentials.json',
                readOnly: true,
              },
            ],
            securityContext: {
              allowPrivilegeEscalation: false,
              readOnlyRootFilesystem: true,
              capabilities: { drop: ['ALL'] },
            },
            resources: { requests: { cpu: '10m', memory: '32Mi' }, limits: { memory: '128Mi' } },
          },
        ],
      },
    },
  });
});
