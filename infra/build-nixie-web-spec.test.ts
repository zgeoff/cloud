// the test asserts the whole spec as one literal, so its body is long
/* oxlint-disable max-lines-per-function */
import { expect, test } from 'bun:test';
import { output } from '@pulumi/pulumi';
import { buildNixieWebSpec } from './build-nixie-web-spec.ts';

test("it runs the web client as its image's user on a read-only root, pointed at nixie's private API", () => {
  const apiURL = output('http://nixie.nixie.svc.cluster.local:8080');

  expect(
    buildNixieWebSpec({
      image:
        'ghcr.io/zgeoff/nixie-web:0.1.0@sha256:318c0b6c6ff89e0b0bbd252df2d04b0120ef28c7266d698ffa9757ff4d2f5754',
      apiURL,
    }),
  ).toStrictEqual({
    replicas: 1,
    selector: { matchLabels: { app: 'nixie-web' } },
    template: {
      metadata: { labels: { app: 'nixie-web' } },
      spec: {
        securityContext: { runAsNonRoot: true, seccompProfile: { type: 'RuntimeDefault' } },
        volumes: [{ name: 'tmp', emptyDir: {} }],
        containers: [
          {
            name: 'web',
            image:
              'ghcr.io/zgeoff/nixie-web:0.1.0@sha256:318c0b6c6ff89e0b0bbd252df2d04b0120ef28c7266d698ffa9757ff4d2f5754',
            ports: [{ name: 'http', containerPort: 3000 }],
            env: [
              { name: 'NIXIE_API_URL', value: apiURL },
              { name: 'PORT', value: '3000' },
            ],
            livenessProbe: {
              httpGet: { path: '/health/live', port: 3000 },
              periodSeconds: 30,
              failureThreshold: 3,
            },
            readinessProbe: { httpGet: { path: '/health/ready', port: 3000 }, periodSeconds: 10 },
            volumeMounts: [{ name: 'tmp', mountPath: '/tmp' }],
            securityContext: {
              allowPrivilegeEscalation: false,
              readOnlyRootFilesystem: true,
              capabilities: { drop: ['ALL'] },
              runAsUser: 1000,
              runAsGroup: 1000,
            },
            resources: { requests: { cpu: '20m', memory: '96Mi' }, limits: { memory: '512Mi' } },
          },
        ],
      },
    },
  });
});
