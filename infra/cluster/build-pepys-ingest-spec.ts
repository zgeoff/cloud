import type { input } from '@pulumi/kubernetes/types';
import type { Output } from '@pulumi/pulumi';
import { buildPepysContainerSecurity } from './build-pepys-container-security.ts';
import { buildPepysPodSecurity } from './build-pepys-pod-security.ts';
import { pepysWorkloads } from './pepys-workloads.ts';

interface PepysIngestSpecInputs {
  // the cloud-pepys image
  readonly image: string;

  // the audience that a telemetry sender's identity token must name; with none, ingest starts and
  // refuses every telemetry export
  readonly impIdentityAudience?: string;

  // the Secret with PEPYS_S2_ACCESS_TOKEN and each secret a route checks
  readonly envSecret: Output<string>;

  // the ConfigMap of trust documents, one JSON file per imp host
  readonly issuersConfigMap: Output<string>;
  readonly pullSecret: string;
}

const ingest = pepysWorkloads.ingest;
const issuersDirectory = '/etc/pepys/imp-issuers';

export function buildPepysIngestSpec(inputs: PepysIngestSpecInputs) {
  return {
    replicas: 1,
    selector: { matchLabels: ingest.labels },
    template: {
      metadata: { labels: ingest.labels },
      spec: {
        ...buildPepysPodSecurity(),
        imagePullSecrets: [{ name: inputs.pullSecret }],
        volumes: [
          { name: 'imp-issuers', configMap: { name: inputs.issuersConfigMap } },
          { name: 'tmp', emptyDir: {} },
        ],
        containers: [
          {
            name: 'ingest',
            image: inputs.image,
            command: ['/usr/local/bin/pepys-ingest'],
            ports: [{ name: 'http', containerPort: ingest.port }],
            env: [
              // ingest listens on 127.0.0.1 unless told, which no Service reaches
              { name: 'PEPYS_INGEST_HOST', value: '0.0.0.0' },
              { name: 'PEPYS_INGEST_PORT', value: String(ingest.port) },
              { name: 'PEPYS_S2_ENDPOINT', value: pepysWorkloads.s2.url },
              { name: 'PEPYS_S2_BASIN', value: pepysWorkloads.s2.basin },
              ...(inputs.impIdentityAudience === undefined
                ? []
                : [{ name: 'PEPYS_IMP_IDENTITY_AUDIENCE', value: inputs.impIdentityAudience }]),
              { name: 'PEPYS_IMP_IDENTITY_ISSUERS', value: issuersDirectory },
            ],
            envFrom: [{ secretRef: { name: inputs.envSecret } }],
            readinessProbe: {
              tcpSocket: { port: ingest.port },
              periodSeconds: 10,
              failureThreshold: 3,
            },
            volumeMounts: [
              { name: 'imp-issuers', mountPath: issuersDirectory, readOnly: true },
              { name: 'tmp', mountPath: '/tmp' },
            ],
            securityContext: buildPepysContainerSecurity(),
            resources: { requests: { cpu: '50m', memory: '128Mi' }, limits: { memory: '256Mi' } },
          },
        ],
      },
    },
  } satisfies input.apps.v1.DeploymentSpec;
}
