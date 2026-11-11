import type { input } from '@pulumi/kubernetes/types';
import type { Output } from '@pulumi/pulumi';
import { buildPepysContainerSecurity } from './build-pepys-container-security.ts';
import { buildPepysPodSecurity } from './build-pepys-pod-security.ts';
import { pepysWorkloads } from './pepys-workloads.ts';

interface PepysGarageSpecInputs {
  readonly image: string;
  readonly serviceName: Output<string>;

  // the ConfigMap that holds deploy/pepys/garage.toml
  readonly configMap: Output<string>;

  // the Secret with GARAGE_RPC_SECRET and GARAGE_ADMIN_TOKEN
  readonly envSecret: Output<string>;
}

const garage = pepysWorkloads.garage;

export function buildPepysGarageSpec(inputs: PepysGarageSpecInputs) {
  return {
    // one node: the cluster has one, and the config sets replication_factor = 1
    replicas: 1,
    updateStrategy: { type: 'RollingUpdate' },
    podManagementPolicy: 'Parallel',
    serviceName: inputs.serviceName,
    selector: { matchLabels: garage.labels },
    template: {
      metadata: { labels: garage.labels },
      spec: {
        ...buildPepysPodSecurity(),
        volumes: [
          { name: 'config', configMap: { name: inputs.configMap } },
          { name: 'tmp', emptyDir: {} },
        ],
        containers: [
          {
            name: 'garage',
            image: inputs.image,

            // --single-node assigns the layout at the first start, so no layout command is run
            command: ['/garage', 'server', '--single-node'],
            ports: [{ name: 's3', containerPort: garage.s3Port }],
            env: [{ name: 'GARAGE_CONFIG_FILE', value: '/etc/garage/garage.toml' }],
            envFrom: [{ secretRef: { name: inputs.envSecret } }],
            readinessProbe: {
              tcpSocket: { port: garage.s3Port },
              periodSeconds: 10,
              failureThreshold: 3,
            },
            volumeMounts: [
              { name: 'config', mountPath: '/etc/garage', readOnly: true },
              { name: 'meta', mountPath: '/var/lib/garage/meta' },
              { name: 'data', mountPath: '/var/lib/garage/data' },
              { name: 'tmp', mountPath: '/tmp' },
            ],
            securityContext: buildPepysContainerSecurity(),
            resources: { requests: { cpu: '50m', memory: '256Mi' }, limits: { memory: '512Mi' } },
          },
        ],
      },
    },
    volumeClaimTemplates: [buildRetainedClaim('meta', '1Gi'), buildRetainedClaim('data', '20Gi')],
  } satisfies input.apps.v1.StatefulSetSpec;
}

function buildRetainedClaim(name: string, storage: string): input.core.v1.PersistentVolumeClaim {
  return {
    metadata: { name },
    spec: {
      accessModes: ['ReadWriteOnce'],

      // keeps the volume when the claim is deleted
      storageClassName: 'local-path-retain',
      resources: { requests: { storage } },
    },
  };
}
