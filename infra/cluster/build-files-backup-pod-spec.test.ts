import { expect, test } from 'bun:test';
import { buildFilesBackupPodSpec } from './build-files-backup-pod-spec.ts';

test("it runs the mounted script's backup on the files claim as the service's own user, pulling the private image with the pull Secret", () => {
  expect(
    buildFilesBackupPodSpec({
      image:
        'ghcr.io/zgeoff/atc-gateway-backup:1.0.0@sha256:1111111111111111111111111111111111111111111111111111111111111111',
      claim: 'data-files-0',
      scriptConfigMap: 'files-backup-script',
      envSecret: 'files-backup',
      pullSecret: 'ghcr-pull',
    }),
  ).toStrictEqual({
    restartPolicy: 'OnFailure',
    securityContext: {
      runAsNonRoot: true,
      runAsUser: 65_532,
      runAsGroup: 65_532,
      fsGroup: 65_532,
      seccompProfile: { type: 'RuntimeDefault' },
    },
    automountServiceAccountToken: false,
    imagePullSecrets: [{ name: 'ghcr-pull' }],
    containers: [
      {
        name: 'backup',
        image:
          'ghcr.io/zgeoff/atc-gateway-backup:1.0.0@sha256:1111111111111111111111111111111111111111111111111111111111111111',
        command: ['/bin/sh', '/opt/files-backup/backup.sh'],
        args: ['backup'],
        env: [
          { name: 'STATE_DIR', value: '/state' },
          { name: 'HOME', value: '/tmp' },
        ],
        envFrom: [{ secretRef: { name: 'files-backup' } }],
        volumeMounts: [
          { name: 'state', mountPath: '/state' },
          { name: 'script', mountPath: '/opt/files-backup', readOnly: true },
          { name: 'tmp', mountPath: '/tmp' },
        ],
        resources: { requests: { cpu: '50m', memory: '64Mi' }, limits: { memory: '256Mi' } },
        securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: ['ALL'] } },
      },
    ],
    volumes: [
      { name: 'state', persistentVolumeClaim: { claimName: 'data-files-0' } },
      { name: 'script', configMap: { name: 'files-backup-script' } },
      { name: 'tmp', emptyDir: {} },
    ],
  });
});
