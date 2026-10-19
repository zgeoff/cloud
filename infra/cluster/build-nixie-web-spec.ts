import type { input } from '@pulumi/kubernetes/types';
import type { Output } from '@pulumi/pulumi';

export const nixieWebPort = 3000;
export const nixieWebLabels = { app: 'nixie-web' };

export interface NixieWebSpecInputs {
  readonly image: string;

  // only the web server calls it; the browser calls /rpc on its own origin
  readonly apiURL: Output<string>;
}

export function buildNixieWebSpec(inputs: NixieWebSpecInputs): input.apps.v1.DeploymentSpec {
  return {
    replicas: 1,
    selector: { matchLabels: nixieWebLabels },
    template: {
      metadata: { labels: nixieWebLabels },
      spec: {
        securityContext: {
          runAsNonRoot: true,
          seccompProfile: { type: 'RuntimeDefault' },
        },
        volumes: [{ name: 'tmp', emptyDir: {} }],
        containers: [
          {
            name: 'web',
            image: inputs.image,
            ports: [{ name: 'http', containerPort: nixieWebPort }],
            env: [
              { name: 'NIXIE_API_URL', value: inputs.apiURL },
              { name: 'PORT', value: String(nixieWebPort) },
            ],
            livenessProbe: {
              httpGet: { path: '/health/live', port: nixieWebPort },
              periodSeconds: 30,
              failureThreshold: 3,
            },

            // ready when it reaches nixie's API
            readinessProbe: {
              httpGet: { path: '/health/ready', port: nixieWebPort },
              periodSeconds: 10,
            },
            volumeMounts: [{ name: 'tmp', mountPath: '/tmp' }],

            // the image's own user, bun
            securityContext: {
              allowPrivilegeEscalation: false,
              readOnlyRootFilesystem: true,
              capabilities: { drop: ['ALL'] },
              runAsUser: 1000,
              runAsGroup: 1000,
            },
            resources: { requests: { cpu: '20m', memory: '96Mi' }, limits: { memory: '512Mi' } },
          },
        ],
      },
    },
  };
}
