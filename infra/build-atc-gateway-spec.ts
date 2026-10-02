import type { input } from '@pulumi/kubernetes/types';
import type { Output } from '@pulumi/pulumi';
import type { ATCGatewayConfig } from './atc-gateway.ts';

export const atcGatewayPort = 8414;
export const atcGatewayLabels = { app: 'atc-gateway' };
const nonrootID = 65_532;
const metadataPath = '/.well-known/oauth-protected-resource/mcp';

interface GatewaySpecInputs {
  readonly config: ATCGatewayConfig;
  readonly claim: Output<string>;
  readonly tokens: Output<string>;
  readonly registry: Output<string>;
}

// The gateway's Deployment spec. atc keeps its state under $HOME/.local/state/atc,
// its config under $HOME/.config/atc and its sockets in $XDG_RUNTIME_DIR. A Bun
// binary extracts native code to /tmp and maps it, so /tmp must allow exec, which an
// emptyDir does.
export function buildATCGatewaySpec(inputs: GatewaySpecInputs): input.apps.v1.DeploymentSpec {
  return {
    replicas: 1,

    // SQLite takes one writer
    strategy: { type: 'Recreate' },
    selector: { matchLabels: atcGatewayLabels },
    template: {
      metadata: { labels: atcGatewayLabels },
      spec: {
        securityContext: buildATCPodSecurity(),
        automountServiceAccountToken: false,
        containers: [buildGatewayContainer(inputs)],
        volumes: [
          { name: 'state', persistentVolumeClaim: { claimName: inputs.claim } },
          { name: 'config', emptyDir: {} },
          { name: 'runtime', emptyDir: { medium: 'Memory' } },
          { name: 'tmp', emptyDir: {} },
          { name: 'registry', configMap: { name: inputs.registry } },
        ],
      },
    },
  };
}

export function buildATCPodSecurity(): input.core.v1.PodSecurityContext {
  return {
    runAsNonRoot: true,
    runAsUser: nonrootID,
    runAsGroup: nonrootID,
    fsGroup: nonrootID,
    seccompProfile: { type: 'RuntimeDefault' },
  };
}

function buildGatewayContainer(inputs: GatewaySpecInputs): input.core.v1.Container {
  const publicHost = new URL(inputs.config.publicURL).host;

  return {
    name: 'atc-gateway',
    image: inputs.config.image,
    args: [
      ...(inputs.config.args ?? ['--host', '0.0.0.0', '--port', String(atcGatewayPort)]),
      '--public-url',
      inputs.config.publicURL,
    ],
    ports: [{ name: 'http', containerPort: atcGatewayPort }],
    envFrom: [{ secretRef: { name: inputs.tokens } }],
    volumeMounts: [
      { name: 'state', mountPath: '/home/nonroot/.local/state/atc' },
      { name: 'config', mountPath: '/home/nonroot/.config' },
      { name: 'runtime', mountPath: '/run/atc' },
      { name: 'tmp', mountPath: '/tmp' },
      { name: 'registry', mountPath: '/etc/atc-gateway', readOnly: true },
    ],
    livenessProbe: {
      ...buildProbe(inputs.config.livenessPath ?? metadataPath, publicHost),
      periodSeconds: 20,
      failureThreshold: 3,
    },
    readinessProbe: {
      ...buildProbe(inputs.config.readinessPath ?? metadataPath, publicHost),
      periodSeconds: 10,
    },
    resources: { requests: { cpu: '50m', memory: '128Mi' }, limits: { memory: '256Mi' } },
    securityContext: {
      readOnlyRootFilesystem: true,
      allowPrivilegeEscalation: false,
      capabilities: { drop: ['ALL'] },
    },
  };
}

// the server answers only its public Host (403 otherwise), so every probe sends it
function buildProbe(path: string, host: string): input.core.v1.Probe {
  return {
    httpGet: { path, port: atcGatewayPort, httpHeaders: [{ name: 'Host', value: host }] },
  };
}
