import { expect, test } from 'bun:test';
import { output } from '@pulumi/pulumi';
import { buildATCGatewayBackupPodSpec } from './build-atc-gateway-backup-pod-spec.ts';

test("it mounts the gateway's claim at STATE_DIR and runs the backup as the gateway's non-root user", () => {
  const claim = output('atc-gateway-state');
  const envSecret = output('atc-gateway-backup');

  expect(
    buildATCGatewayBackupPodSpec({
      image:
        'ghcr.io/zgeoff/atc-gateway-backup:1.0.0@sha256:1111111111111111111111111111111111111111111111111111111111111111',
      claim,
      envSecret,
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
    containers: [
      {
        name: 'backup',
        image:
          'ghcr.io/zgeoff/atc-gateway-backup:1.0.0@sha256:1111111111111111111111111111111111111111111111111111111111111111',
        args: ['backup'],
        env: [
          { name: 'STATE_DIR', value: '/state' },
          { name: 'HOME', value: '/tmp' },
        ],
        envFrom: [{ secretRef: { name: envSecret } }],
        volumeMounts: [
          { name: 'state', mountPath: '/state' },
          { name: 'tmp', mountPath: '/tmp' },
        ],
        resources: { requests: { cpu: '50m', memory: '64Mi' }, limits: { memory: '256Mi' } },
        securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: ['ALL'] } },
      },
    ],
    volumes: [
      { name: 'state', persistentVolumeClaim: { claimName: claim } },
      { name: 'tmp', emptyDir: {} },
    ],
  });
});
