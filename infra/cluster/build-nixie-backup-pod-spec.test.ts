import { expect, test } from 'bun:test';
import { buildNixieBackupPodSpec } from './build-nixie-backup-pod-spec.ts';

test("it copies nixie's data with nixie's own backup command and uploads the copy with the mounted script, which never mounts nixie's claim", () => {
  expect(
    buildNixieBackupPodSpec({
      image:
        'ghcr.io/zgeoff/atc-gateway-backup:1.0.0@sha256:1111111111111111111111111111111111111111111111111111111111111111',
      nixieImage:
        'ghcr.io/zgeoff/nixie:1.0.0@sha256:2222222222222222222222222222222222222222222222222222222222222222',
      claim: 'data-nixie-0',
      scriptConfigMap: 'nixie-backup-script',
      configMap: 'nixie-backup-config',
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
    initContainers: [
      {
        name: 'copy',
        image:
          'ghcr.io/zgeoff/nixie:1.0.0@sha256:2222222222222222222222222222222222222222222222222222222222222222',
        command: ['nixie', 'backup', '--to', '/tmp/nixie-backup'],
        volumeMounts: [
          { name: 'state', mountPath: '/data' },
          {
            name: 'config',
            mountPath: '/etc/nixie/config.yaml',
            subPath: 'config.yaml',
            readOnly: true,
          },
          { name: 'tmp', mountPath: '/tmp' },
        ],
        resources: { requests: { cpu: '50m', memory: '128Mi' }, limits: { memory: '512Mi' } },
        securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: ['ALL'] } },
      },
    ],
    containers: [
      {
        name: 'backup',
        image:
          'ghcr.io/zgeoff/atc-gateway-backup:1.0.0@sha256:1111111111111111111111111111111111111111111111111111111111111111',
        command: ['/bin/sh', '/opt/nixie-backup/backup.sh'],
        args: ['backup'],
        env: [{ name: 'HOME', value: '/tmp' }],
        envFrom: [{ secretRef: { name: 'nixie-backup' } }],
        volumeMounts: [
          { name: 'script', mountPath: '/opt/nixie-backup', readOnly: true },
          { name: 'tmp', mountPath: '/tmp' },
        ],
        resources: { requests: { cpu: '50m', memory: '64Mi' }, limits: { memory: '256Mi' } },
        securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: ['ALL'] } },
      },
    ],
    volumes: [
      { name: 'state', persistentVolumeClaim: { claimName: 'data-nixie-0' } },
      { name: 'config', configMap: { name: 'nixie-backup-config' } },
      { name: 'script', configMap: { name: 'nixie-backup-script' } },
      { name: 'tmp', emptyDir: {} },
    ],
  });
});
