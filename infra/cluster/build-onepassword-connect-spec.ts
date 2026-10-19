import type { input } from '@pulumi/kubernetes/types';
import type { Output } from '@pulumi/pulumi';

export const onePasswordConnectAPIPort = 8080;
export const onePasswordConnectLabels = { app: 'onepassword-connect' };
export const onePasswordConnectCredentialsKey = '1password-credentials.json';
const connectVersion = '1.8.3';
const connectAPIImage = `1password/connect-api:${connectVersion}`;
const connectSyncImage = `1password/connect-sync:${connectVersion}`;

const podSecurityContext: input.core.v1.PodSecurityContext = {
  fsGroup: 999,
  runAsUser: 999,
  runAsGroup: 999,
  runAsNonRoot: true,
  seccompProfile: { type: 'RuntimeDefault' },
};

// follows charts/connect in 1Password/connect-helm-charts
export function buildOnePasswordConnectSpec(
  credentialsSecret: Output<string>,
): input.apps.v1.DeploymentSpec {
  return {
    replicas: 1,
    selector: { matchLabels: onePasswordConnectLabels },
    template: {
      metadata: { labels: onePasswordConnectLabels },
      spec: {
        securityContext: podSecurityContext,
        volumes: [
          { name: 'shared-data', emptyDir: {} },
          { name: 'credentials', secret: { secretName: credentialsSecret } },
        ],
        containers: [
          buildConnectContainer({
            name: 'connect-api',
            image: connectAPIImage,
            httpPort: onePasswordConnectAPIPort,
            busPort: 11_220,
            peerPort: 11_221,
            memory: '128Mi',
          }),
          buildConnectContainer({
            name: 'connect-sync',
            image: connectSyncImage,
            httpPort: 8081,
            busPort: 11_221,
            peerPort: 11_220,
            memory: '128Mi',
          }),
        ],
      },
    },
  };
}

interface ConnectContainer {
  readonly name: string;
  readonly image: string;
  readonly httpPort: number;
  readonly busPort: number;
  readonly peerPort: number;
  readonly memory: string;
}

const lockedDown: input.core.v1.SecurityContext = {
  allowPrivilegeEscalation: false,
  readOnlyRootFilesystem: true,
  capabilities: { drop: ['ALL'] },
};

const credentialsPath = `/home/opuser/.op/${onePasswordConnectCredentialsKey}`;
const dataPath = '/home/opuser/.op/data';

function buildConnectContainer(spec: ConnectContainer): input.core.v1.Container {
  return {
    name: spec.name,
    image: spec.image,
    env: [
      { name: 'OP_HTTP_PORT', value: String(spec.httpPort) },
      { name: 'OP_SESSION', value: credentialsPath },
      { name: 'OP_BUS_PORT', value: String(spec.busPort) },
      { name: 'OP_BUS_PEERS', value: `localhost:${spec.peerPort}` },
      { name: 'OP_LOG_LEVEL', value: 'info' },
    ],
    readinessProbe: { httpGet: { path: '/health', port: spec.httpPort } },
    livenessProbe: {
      httpGet: { path: '/heartbeat', port: spec.httpPort },
      periodSeconds: 30,
      failureThreshold: 3,
      initialDelaySeconds: 15,
    },
    volumeMounts: [
      { name: 'shared-data', mountPath: dataPath },
      {
        name: 'credentials',
        mountPath: credentialsPath,
        subPath: onePasswordConnectCredentialsKey,
        readOnly: true,
      },
    ],
    securityContext: lockedDown,
    resources: { requests: { cpu: '10m', memory: '32Mi' }, limits: { memory: spec.memory } },
  };
}
