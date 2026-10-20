import type { input } from '@pulumi/kubernetes/types';
import type { Output } from '@pulumi/pulumi';
import { topology } from '@zgeoff/cloud-topology';
import type { ATCGatewayConfig } from '../inputs/index.ts';
import { cloudflaredImage } from '../shared/cloudflared-image.ts';

export const atcGatewayLabels = { app: 'atc-gateway' };
const nonrootID = 65_532;

interface GatewaySpecInputs {
  readonly config: ATCGatewayConfig;
  readonly publicHost: string;
  readonly claim: Output<string>;
  readonly tokens: Output<string>;
  readonly registry: Output<string>;
  readonly pullSecret: Output<string>;
  readonly tunnelToken: Output<string>;
}

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
        imagePullSecrets: [{ name: inputs.pullSecret }],
        containers: [buildGatewayContainer(inputs), buildTunnelContainer()],
        volumes: [
          { name: 'state', persistentVolumeClaim: { claimName: inputs.claim } },
          { name: 'config', emptyDir: {} },
          { name: 'runtime', emptyDir: { medium: 'Memory' } },

          // /tmp needs exec for Bun's extracted natives, which an emptyDir allows
          { name: 'tmp', emptyDir: {} },
          { name: 'registry', configMap: { name: inputs.registry } },

          // group-readable, so the nonroot user reads it through fsGroup
          { name: 'tunnel-token', secret: { secretName: inputs.tunnelToken, defaultMode: 0o440 } },
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

export const atcGatewayRegistryFile = 'registry.json';
const registryDir = '/etc/atc-gateway';

// $HOME/.local/state/atc, until atc's packaging names the gateway's state path
const defaultStateDir = '/home/nonroot/.local/state/atc';

export const atcGatewayPort = topology.atc.gatewayPort;

function buildGatewayContainer(inputs: GatewaySpecInputs): input.core.v1.Container {
  const stateDir = inputs.config.stateDir ?? defaultStateDir;

  return {
    name: 'atc-gateway',
    image: inputs.config.image,
    args: [
      'serve',
      '--host',
      '0.0.0.0',
      '--port',
      String(atcGatewayPort),
      '--public-url',
      inputs.config.publicURL,
      '--registry',
      `${registryDir}/${atcGatewayRegistryFile}`,
      '--state-dir',
      stateDir,
      ...(inputs.config.trustForwardedFrom ?? []).flatMap((address) => [
        '--trust-forwarded-from',
        address,
      ]),
    ],
    ports: [{ name: 'http', containerPort: atcGatewayPort }],

    envFrom: [{ secretRef: { name: inputs.tokens } }],

    // for `kubectl exec … atc-gateway clients`, which has no --state-dir of its own here;
    // it must equal --state-dir, or atc-gateway exits on the conflict
    env: [{ name: 'ATC_GATEWAY_STATE_DIR', value: stateDir }],
    volumeMounts: [
      { name: 'state', mountPath: stateDir },
      { name: 'config', mountPath: '/home/nonroot/.config' },
      { name: 'runtime', mountPath: '/run/atc' },
      { name: 'tmp', mountPath: '/tmp' },
      { name: 'registry', mountPath: registryDir, readOnly: true },
    ],
    livenessProbe: {
      ...buildProbe('/healthz', inputs.publicHost),
      periodSeconds: 20,
      failureThreshold: 3,
    },
    readinessProbe: { ...buildProbe('/readyz', inputs.publicHost), periodSeconds: 10 },
    resources: { requests: { cpu: '50m', memory: '128Mi' }, limits: { memory: '256Mi' } },
    securityContext: {
      readOnlyRootFilesystem: true,
      allowPrivilegeEscalation: false,
      capabilities: { drop: ['ALL'] },
    },
  };
}

function buildProbe(path: string, host: string): input.core.v1.Probe {
  return {
    // the server answers only its public Host (403 otherwise), so every probe sends it
    httpGet: { path, port: atcGatewayPort, httpHeaders: [{ name: 'Host', value: host }] },
  };
}

const tunnelTokenDir = '/etc/cloudflared';

function buildTunnelContainer(): input.core.v1.Container {
  return {
    name: 'cloudflared',
    image: cloudflaredImage,
    args: [
      'tunnel',
      '--no-autoupdate',
      '--metrics',

      // loopback, so nothing outside the pod reaches the metrics, which leaves kubelet no port to
      // probe
      '127.0.0.1:2000',
      'run',
      '--token-file',
      `${tunnelTokenDir}/token`,
    ],
    volumeMounts: [{ name: 'tunnel-token', mountPath: tunnelTokenDir, readOnly: true }],
    resources: {
      requests: { cpu: '10m', memory: '32Mi' },
      limits: { cpu: '200m', memory: '128Mi' },
    },
    securityContext: {
      runAsNonRoot: true,
      readOnlyRootFilesystem: true,
      allowPrivilegeEscalation: false,
      capabilities: { drop: ['ALL'] },
    },
  };
}
