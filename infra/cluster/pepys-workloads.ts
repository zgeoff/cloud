import { topology } from '@zgeoff/cloud-topology';

// The namespace and the Services have fixed names, so each in-cluster URL is known before an apply
// and the processes can name each other in their environment.
const namespace = 'pepys';

export const pepysWorkloads = {
  namespace,
  garage: {
    name: 'pepys-garage',
    labels: { app: 'pepys-garage' },
    s3Port: 3900,
    url: `http://pepys-garage.${namespace}.svc.cluster.local:3900`,
  },
  s2: {
    name: 'pepys-s2',
    labels: { app: 'pepys-s2' },
    port: 8080,
    url: `http://pepys-s2.${namespace}.svc.cluster.local:8080`,

    // the bucket and the path in it that hold the fact log
    bucket: 'facts',
    path: 's2lite',

    // S2 refuses a basin name shorter than 8 bytes
    basin: 'pepys-facts',
  },
  ingest: {
    name: 'pepys-ingest',
    labels: { app: 'pepys-ingest' },
    port: topology.pepysIngest.port,
    url: `http://pepys-ingest.${namespace}.svc.cluster.local:${topology.pepysIngest.port}`,

    // the host's telemetry relay dials this address, so a cluster rebuild must keep it free
    clusterIP: topology.pepysIngest.clusterIP,
  },
  host: {
    name: 'pepys-host',
    labels: { app: 'pepys-host' },
    apiPort: 8081,
    url: `http://pepys-host.${namespace}.svc.cluster.local:8081`,
  },
  backup: {
    name: 'pepys-backup',
    labels: { app: 'pepys-backup' },

    // the buckets a store writes today; the backup copies each one
    buckets: ['facts'],
  },
} as const;

// the images' nonroot user
export const pepysUserID = 65_532;
