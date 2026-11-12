import type { input } from '@pulumi/kubernetes/types';
import type { Output } from '@pulumi/pulumi';
import { buildPepysContainerSecurity } from './build-pepys-container-security.ts';
import { buildPepysPodSecurity } from './build-pepys-pod-security.ts';
import { pepysWorkloads } from './pepys-workloads.ts';

interface PepysHostSpecInputs {
  // the cloud-pepys image
  readonly image: string;
  readonly serviceName: Output<string>;

  // the Secret with PEPYS_S2_ACCESS_TOKEN
  readonly envSecret: Output<string>;
  readonly pullSecret: string;
}

const host = pepysWorkloads.host;

// The host and the API share one pod, because the API reads the store files that the host writes.
export function buildPepysHostSpec(inputs: PepysHostSpecInputs) {
  return {
    // the store takes one writer
    replicas: 1,
    updateStrategy: { type: 'RollingUpdate' },
    podManagementPolicy: 'Parallel',
    serviceName: inputs.serviceName,
    selector: { matchLabels: host.labels },
    template: {
      metadata: { labels: host.labels },
      spec: {
        ...buildPepysPodSecurity(),
        imagePullSecrets: [{ name: inputs.pullSecret }],
        volumes: [{ name: 'tmp', emptyDir: {} }],
        containers: [buildHostContainer(inputs), buildAPIContainer(inputs)],
      },
    },
    volumeClaimTemplates: [
      {
        metadata: { name: 'store' },
        spec: {
          accessModes: ['ReadWriteOnce'],

          // keeps the volume when the claim is deleted
          storageClassName: 'local-path-retain',
          resources: { requests: { storage: '10Gi' } },
        },
      },
    ],
  } satisfies input.apps.v1.StatefulSetSpec;
}

const storeDirectory = '/store';

function buildHostContainer(inputs: PepysHostSpecInputs): input.core.v1.Container {
  return {
    name: 'host',
    image: inputs.image,

    // --up deploys each listed consumer version before the host tails its streams
    command: ['/usr/local/bin/pepys-host', 'run', '--up'],
    env: [
      { name: 'PEPYS_S2_ENDPOINT', value: pepysWorkloads.s2.url },
      { name: 'PEPYS_S2_BASIN', value: pepysWorkloads.s2.basin },
      { name: 'PEPYS_STORE_DIR', value: storeDirectory },
      { name: 'PEPYS_CONSUMERS', value: '/modules/consumers.json' },
    ],
    envFrom: [{ secretRef: { name: inputs.envSecret } }],
    volumeMounts: [
      { name: 'store', mountPath: storeDirectory },
      { name: 'tmp', mountPath: '/tmp' },
    ],
    securityContext: buildPepysContainerSecurity(),
    resources: { requests: { cpu: '50m', memory: '192Mi' }, limits: { memory: '512Mi' } },
  };
}

function buildAPIContainer(inputs: PepysHostSpecInputs): input.core.v1.Container {
  return {
    name: 'api',
    image: inputs.image,
    command: ['/usr/local/bin/pepys-api'],
    ports: [{ name: 'http', containerPort: host.apiPort }],
    env: [
      { name: 'PEPYS_STORE_DIR', value: storeDirectory },

      // the API listens on 127.0.0.1 unless told, which no Service reaches
      { name: 'PEPYS_API_HOST', value: '0.0.0.0' },
      { name: 'PEPYS_API_PORT', value: String(host.apiPort) },
    ],
    readinessProbe: { tcpSocket: { port: host.apiPort }, periodSeconds: 10, failureThreshold: 3 },

    // read-write: the store's database files keep their lock and WAL index beside them. The
    // compiled API writes Turso's embedded native addon to /tmp and loads it from there, so /tmp
    // must allow exec, as an emptyDir does
    volumeMounts: [
      { name: 'store', mountPath: storeDirectory },
      { name: 'tmp', mountPath: '/tmp' },
    ],
    securityContext: buildPepysContainerSecurity(),
    resources: { requests: { cpu: '50m', memory: '64Mi' }, limits: { memory: '256Mi' } },
  };
}
