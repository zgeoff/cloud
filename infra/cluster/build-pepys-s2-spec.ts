import type { input } from '@pulumi/kubernetes/types';
import type { Output } from '@pulumi/pulumi';
import { pepysWorkloads } from '../shared/pepys-workloads.ts';
import { buildPepysContainerSecurity } from './build-pepys-container-security.ts';
import { buildPepysPodSecurity } from './build-pepys-pod-security.ts';

interface PepysS2SpecInputs {
  readonly image: string;

  // the Secret with s2-lite's Garage key, as AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY
  readonly envSecret: Output<string>;
}

const s2 = pepysWorkloads.s2;

export function buildPepysS2Spec(inputs: PepysS2SpecInputs) {
  return {
    replicas: 1,

    // two s2-lite processes on one bucket path would both write the log
    strategy: { type: 'Recreate' },
    selector: { matchLabels: s2.labels },
    template: {
      metadata: { labels: s2.labels },
      spec: {
        ...buildPepysPodSecurity(),
        volumes: [{ name: 'tmp', emptyDir: {} }],
        containers: [
          {
            name: 's2',
            image: inputs.image,
            args: ['lite', '--bucket', s2.bucket, '--path', s2.path, '--port', String(s2.port)],
            ports: [{ name: 'http', containerPort: s2.port }],
            env: [
              { name: 'AWS_ENDPOINT_URL_S3', value: pepysWorkloads.garage.url },
              { name: 'AWS_REGION', value: 'garage' },
              { name: 'RUST_LOG', value: 'info' },
            ],
            envFrom: [{ secretRef: { name: inputs.envSecret } }],
            readinessProbe: {
              tcpSocket: { port: s2.port },
              periodSeconds: 10,
              failureThreshold: 3,
            },
            volumeMounts: [{ name: 'tmp', mountPath: '/tmp' }],
            securityContext: buildPepysContainerSecurity(),

            // s2-lite idles near 80Mi, and a compaction adds to that: at a 512Mi limit the kernel
            // OOM-killed it at 514MiB after 29 hours, and again at 507MiB two minutes after it
            // started.
            resources: { requests: { cpu: '50m', memory: '256Mi' }, limits: { memory: '1Gi' } },
          },
        ],
      },
    },
  } satisfies input.apps.v1.DeploymentSpec;
}
