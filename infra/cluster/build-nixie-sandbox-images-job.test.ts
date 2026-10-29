import { expect, test } from 'bun:test';
import { buildNixieSandboxImagesJob } from './build-nixie-sandbox-images-job.ts';

test("it runs the add once in the new nixie image, as nixie's user on a read-only root, with only the sops file and the age key of nixie's Secret", () => {
  expect(
    buildNixieSandboxImagesJob({
      image:
        'ghcr.io/zgeoff/nixie:0.43.0@sha256:06d8802f4aac382106d53be0915887e86e36c6960e2404e19af6611a4c01b309',
      secret: 'nixie-secrets-test',
    }),
  ).toStrictEqual({
    apiVersion: 'batch/v1',
    kind: 'Job',
    metadata: {
      generateName: 'nixie-sandbox-images-',
      namespace: 'nixie',
      labels: { app: 'nixie-sandbox-images' },
    },
    spec: {
      backoffLimit: 0,
      activeDeadlineSeconds: 900,
      ttlSecondsAfterFinished: 86_400,
      template: {
        metadata: { labels: { app: 'nixie-sandbox-images' } },
        spec: {
          restartPolicy: 'Never',
          automountServiceAccountToken: false,
          enableServiceLinks: false,
          securityContext: {
            fsGroup: 10_001,
            runAsNonRoot: true,
            seccompProfile: { type: 'RuntimeDefault' },
          },
          volumes: [
            {
              name: 'secrets',
              secret: {
                secretName: 'nixie-secrets-test',
                defaultMode: 0o440,
                items: [
                  { key: 'secrets.yaml', path: 'secrets.yaml' },
                  { key: 'age-key.txt', path: 'age-key.txt' },
                ],
              },
            },
            {
              name: 'script',
              configMap: {
                name: 'nixie-sandbox-images',
                items: [{ key: 'add-sandbox-images.js', path: 'add-sandbox-images.js' }],
              },
            },
            { name: 'tmp', emptyDir: {} },
          ],
          containers: [
            {
              name: 'add',
              image:
                'ghcr.io/zgeoff/nixie:0.43.0@sha256:06d8802f4aac382106d53be0915887e86e36c6960e2404e19af6611a4c01b309',
              command: ['bun', '/opt/nixie-sandbox-images/add-sandbox-images.js'],
              env: [
                { name: 'IMPD_URL', value: 'https://imps.geoff.cloud' },
                { name: 'NIXIE_SECRETS_FILE', value: '/etc/nixie/secrets/secrets.yaml' },
                { name: 'SOPS_AGE_KEY_FILE', value: '/etc/nixie/secrets/age-key.txt' },
                { name: 'HOME', value: '/tmp' },
              ],
              volumeMounts: [
                { name: 'secrets', mountPath: '/etc/nixie/secrets', readOnly: true },
                { name: 'script', mountPath: '/opt/nixie-sandbox-images', readOnly: true },
                { name: 'tmp', mountPath: '/tmp' },
              ],
              securityContext: {
                allowPrivilegeEscalation: false,
                readOnlyRootFilesystem: true,
                capabilities: { drop: ['ALL'] },
                runAsUser: 10_001,
                runAsGroup: 10_001,
              },
              resources: { requests: { cpu: '50m', memory: '128Mi' }, limits: { memory: '512Mi' } },
            },
          ],
        },
      },
    },
  });
});
