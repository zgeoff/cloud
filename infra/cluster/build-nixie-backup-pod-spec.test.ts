import { expect, test } from 'bun:test';
import { buildNixieBackupPodSpec } from './build-nixie-backup-pod-spec.ts';

test("it runs the nixie-backup image's own job on the staging folder alone, never restarted, after an init container with no secret creates the folder", () => {
  expect(
    buildNixieBackupPodSpec({
      image:
        'ghcr.io/zgeoff/nixie-backup:1.0.0@sha256:1111111111111111111111111111111111111111111111111111111111111111',
      claim: 'data-nixie-0',
      envSecret: 'nixie-backup',
      pullSecret: 'ghcr-pull',
    }),
  ).toStrictEqual({
    restartPolicy: 'Never',
    securityContext: {
      runAsNonRoot: true,
      runAsUser: 10_001,
      runAsGroup: 10_001,
      fsGroup: 10_001,
      seccompProfile: { type: 'RuntimeDefault' },
    },
    automountServiceAccountToken: false,
    imagePullSecrets: [{ name: 'ghcr-pull' }],
    initContainers: [
      {
        name: 'staging',
        image:
          'ghcr.io/zgeoff/nixie-backup:1.0.0@sha256:1111111111111111111111111111111111111111111111111111111111111111',
        command: ['mkdir', '-p', '-m', '0700', '/state/backup'],
        volumeMounts: [{ name: 'state', mountPath: '/state' }],
        resources: { requests: { cpu: '10m', memory: '16Mi' }, limits: { memory: '32Mi' } },
        securityContext: {
          allowPrivilegeEscalation: false,
          readOnlyRootFilesystem: true,
          capabilities: { drop: ['ALL'] },
        },
      },
    ],
    containers: [
      {
        name: 'backup',
        image:
          'ghcr.io/zgeoff/nixie-backup:1.0.0@sha256:1111111111111111111111111111111111111111111111111111111111111111',
        args: ['run'],
        env: [
          { name: 'NIXIE_BACKUP_STAGING_DIR', value: '/backup' },
          { name: 'HOME', value: '/tmp' },
        ],
        envFrom: [{ secretRef: { name: 'nixie-backup' } }],
        volumeMounts: [
          { name: 'state', mountPath: '/backup', subPath: 'backup' },
          { name: 'tmp', mountPath: '/tmp' },
        ],
        resources: { requests: { cpu: '50m', memory: '128Mi' }, limits: { memory: '512Mi' } },
        securityContext: {
          allowPrivilegeEscalation: false,
          readOnlyRootFilesystem: true,
          capabilities: { drop: ['ALL'] },
        },
      },
    ],
    volumes: [
      { name: 'state', persistentVolumeClaim: { claimName: 'data-nixie-0' } },
      { name: 'tmp', emptyDir: {} },
    ],
  });
});
