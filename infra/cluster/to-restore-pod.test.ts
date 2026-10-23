import { expect, test } from 'bun:test';
import { toRestorePod } from './to-restore-pod.ts';

test("it runs the backup pod's restore once, without the backup's resources", () => {
  expect(
    toRestorePod({
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
    }),
  ).toStrictEqual({
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
  });
});
