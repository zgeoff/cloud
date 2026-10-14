// the test asserts the whole Job as one literal, so its body is long
/* oxlint-disable max-lines-per-function */
import { expect, test } from 'bun:test';
import { buildRestoreJob } from './build-restore-job.ts';

test("it runs the backup pod's restore once, without the backup's resources, in a one-off Job", () => {
  expect(
    buildRestoreJob({
      name: 'ledger',
      namespace: 'books',
      backupPod: {
        restartPolicy: 'OnFailure',
        automountServiceAccountToken: false,
        containers: [
          {
            name: 'backup',
            image:
              'ghcr.io/zgeoff/atc-gateway-backup:1.0.0@sha256:1111111111111111111111111111111111111111111111111111111111111111',
            command: ['/bin/sh', '/opt/ledger/backup.sh'],
            args: ['backup'],
            env: [{ name: 'STATE_DIR', value: '/state' }],
            envFrom: [{ secretRef: { name: 'ledger-backup' } }],
            resources: { limits: { memory: '256Mi' } },
          },
        ],
        volumes: [{ name: 'state', persistentVolumeClaim: { claimName: 'ledger-data' } }],
      },
    }),
  ).toStrictEqual({
    apiVersion: 'batch/v1',
    kind: 'Job',
    metadata: { generateName: 'ledger-restore-', namespace: 'books' },
    spec: {
      backoffLimit: 0,
      ttlSecondsAfterFinished: 86_400,
      template: {
        spec: {
          restartPolicy: 'Never',
          automountServiceAccountToken: false,
          containers: [
            {
              name: 'restore',
              image:
                'ghcr.io/zgeoff/atc-gateway-backup:1.0.0@sha256:1111111111111111111111111111111111111111111111111111111111111111',
              command: ['/bin/sh', '/opt/ledger/backup.sh'],
              args: ['restore'],
              env: [
                { name: 'STATE_DIR', value: '/state' },
                { name: 'SNAPSHOT', value: 'latest' },
              ],
              envFrom: [{ secretRef: { name: 'ledger-backup' } }],
            },
          ],
          volumes: [{ name: 'state', persistentVolumeClaim: { claimName: 'ledger-data' } }],
        },
      },
    },
  });
});
