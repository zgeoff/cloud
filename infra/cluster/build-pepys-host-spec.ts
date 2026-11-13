import type { input } from '@pulumi/kubernetes/types';
import type { Output } from '@pulumi/pulumi';
import { pepysWorkloads } from '../shared/pepys-workloads.ts';
import { buildPepysContainerSecurity } from './build-pepys-container-security.ts';
import { buildPepysPodSecurity } from './build-pepys-pod-security.ts';

interface PepysMCPInputs {
  // the https origin that MCP clients reach the API at, and the OAuth issuer
  readonly publicURL: string;

  // the claim of the volume that holds the OAuth server's database
  readonly authClaim: Output<string>;
}

interface PepysHostSpecInputs {
  // the cloud-pepys image
  readonly image: string;
  readonly serviceName: Output<string>;

  // the Secret with PEPYS_S2_ACCESS_TOKEN
  readonly envSecret: Output<string>;
  readonly pullSecret: string;

  // set while the API serves /mcp on its public hostname
  readonly mcp?: PepysMCPInputs;
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
        volumes: [
          { name: 'tmp', emptyDir: {} },
          ...(inputs.mcp === undefined
            ? []
            : [{ name: 'auth', persistentVolumeClaim: { claimName: inputs.mcp.authClaim } }]),
        ],
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

const authDirectory = '/auth';

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

      // the API exits at start with a public URL and no auth folder, so the two come together
      ...(inputs.mcp === undefined
        ? []
        : [
            { name: 'PEPYS_API_PUBLIC_URL', value: inputs.mcp.publicURL },
            { name: 'PEPYS_AUTH_DIR', value: authDirectory },
          ]),
    ],
    readinessProbe: { tcpSocket: { port: host.apiPort }, periodSeconds: 10, failureThreshold: 3 },

    // read-write: the store's database files keep their lock and WAL index beside them. The
    // compiled API writes Turso's embedded native addon to /tmp and loads it from there, so /tmp
    // must allow exec, as an emptyDir does
    volumeMounts: [
      { name: 'store', mountPath: storeDirectory },
      { name: 'tmp', mountPath: '/tmp' },
      ...(inputs.mcp === undefined ? [] : [{ name: 'auth', mountPath: authDirectory }]),
    ],
    securityContext: buildPepysContainerSecurity(),
    resources: { requests: { cpu: '50m', memory: '64Mi' }, limits: { memory: '256Mi' } },
  };
}
