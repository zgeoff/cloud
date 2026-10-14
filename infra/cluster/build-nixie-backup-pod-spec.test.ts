import { expect, test } from 'bun:test';
import { buildNixieBackupPodSpec } from './build-nixie-backup-pod-spec.ts';

test("it runs the mounted script's backup on nixie's claim as nixie's own user, pulling the private image with the pull Secret", () => {
  expect(
    buildNixieBackupPodSpec({
      image:
        'ghcr.io/zgeoff/atc-gateway-backup:1.0.0@sha256:1111111111111111111111111111111111111111111111111111111111111111',
      claim: 'data-nixie-0',
      scriptConfigMap: 'nixie-backup-script',
      envSecret: 'nixie-backup',
      pullSecret: 'ghcr-pull',
    }),
  ).toStrictEqual({
    restartPolicy: 'OnFailure',
    securityContext: {
      runAsNonRoot: true,
      runAsUser: 10_001,
      runAsGroup: 10_001,
      fsGroup: 10_001,
      seccompProfile: { type: 'RuntimeDefault' },
    },
    automountServiceAccountToken: false,
    imagePullSecrets: [{ name: 'ghcr-pull' }],
    containers: [
      {
        name: 'backup',
        image:
          'ghcr.io/zgeoff/atc-gateway-backup:1.0.0@sha256:1111111111111111111111111111111111111111111111111111111111111111',
        command: ['/bin/sh', '/opt/nixie-backup/backup.sh'],
        args: ['backup'],
        env: [
          { name: 'STATE_DIR', value: '/state' },
          { name: 'HOME', value: '/tmp' },
        ],
        envFrom: [{ secretRef: { name: 'nixie-backup' } }],
        volumeMounts: [
          { name: 'state', mountPath: '/state' },
          { name: 'script', mountPath: '/opt/nixie-backup', readOnly: true },
          { name: 'tmp', mountPath: '/tmp' },
        ],
        resources: { requests: { cpu: '50m', memory: '64Mi' }, limits: { memory: '256Mi' } },
        securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: ['ALL'] } },
      },
    ],
    volumes: [
      { name: 'state', persistentVolumeClaim: { claimName: 'data-nixie-0' } },
      { name: 'script', configMap: { name: 'nixie-backup-script' } },
      { name: 'tmp', emptyDir: {} },
    ],
  });
});
