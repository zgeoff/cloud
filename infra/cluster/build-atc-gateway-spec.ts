import type { input } from '@pulumi/kubernetes/types';
import type { Output } from '@pulumi/pulumi';
import { topology } from '@zgeoff/cloud-topology';
import type { ATCGatewayConfig } from '../inputs/index.ts';
import { cloudflaredImage } from '../shared/cloudflared-image.ts';
import { podLabels } from '../shared/pod-labels.ts';
import { atcGatewayServiceTokenFile } from './build-atc-gateway-service-token-file.ts';

export const atcGatewayLabels = podLabels.atcGateway;
const nonrootID = 65_532;

interface GatewaySpecInputs {
  readonly config: ATCGatewayConfig;
  readonly publicHost: string;
  readonly claim: Output<string>;
  readonly tokens: Output<string>;
  readonly registry: Output<string>;
  readonly pullSecret: Output<string>;
  readonly tunnelToken: Output<string>;

  // the Secret that holds the service token file; with it the gateway reads --service-token-file
  readonly serviceTokens?: Output<string>;
}

export function buildATCGatewaySpec(inputs: GatewaySpecInputs) {
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
        ...(inputs.serviceTokens === undefined
          ? {}
          : { initContainers: [buildServiceTokenContainer(inputs.config.backupImage)] }),
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
          ...buildServiceTokenVolumes(inputs.serviceTokens),
        ],
      },
    },
  } satisfies input.apps.v1.DeploymentSpec;
}

// where the init container reads the Secret and writes its copy
const serviceTokenSourceDir = '/service-token-source';
const serviceTokenCopyDir = '/service-token';

// atc refuses a token file that another user owns or that others can open, and a Secret volume's
// files belong to root. So an init container, running as the gateway's user in the backup image
// (alpine has a shell; the gateway's image is distroless), copies the file with mode 0600.
function buildServiceTokenContainer(image: string) {
  return {
    name: 'service-token',
    image,
    command: [
      'sh',
      '-c',
      `umask 077 && cat ${serviceTokenSourceDir}/${atcGatewayServiceTokenFile} > ${serviceTokenCopyDir}/${atcGatewayServiceTokenFile}`,
    ],
    volumeMounts: [
      { name: 'service-token-source', mountPath: serviceTokenSourceDir, readOnly: true },
      { name: 'service-token', mountPath: serviceTokenCopyDir },
    ],
    resources: { requests: { cpu: '10m', memory: '16Mi' }, limits: { memory: '32Mi' } },
    securityContext: {
      runAsNonRoot: true,
      readOnlyRootFilesystem: true,
      allowPrivilegeEscalation: false,
      capabilities: { drop: ['ALL'] },
    },
  } satisfies input.core.v1.Container;
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

// atc's default, $HOME/.local/state/atc: atc's packaging names no state path for the gateway
const defaultStateDir = '/home/nonroot/.local/state/atc';

export const atcGatewayPort = topology.atc.gatewayPort;

// where the gateway reads the service token file
const serviceTokenDir = '/etc/atc-gateway-service-tokens';

function buildGatewayContainer(inputs: GatewaySpecInputs) {
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
      ...(inputs.serviceTokens === undefined
        ? []
        : ['--service-token-file', `${serviceTokenDir}/${atcGatewayServiceTokenFile}`]),
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
      ...(inputs.serviceTokens === undefined
        ? []
        : [{ name: 'service-token', mountPath: serviceTokenDir, readOnly: true }]),
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
  } satisfies input.core.v1.Container;
}

function buildProbe(path: string, host: string): input.core.v1.Probe {
  return {
    // the server answers only its public Host (403 otherwise), so every probe sends it
    httpGet: { path, port: atcGatewayPort, httpHeaders: [{ name: 'Host', value: host }] },
  };
}

const tunnelTokenDir = '/etc/cloudflared';

function buildTunnelContainer() {
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
  } satisfies input.core.v1.Container;
}

function buildServiceTokenVolumes(secretName: Output<string> | undefined): input.core.v1.Volume[] {
  if (secretName === undefined) {
    return [];
  }

  return [
    // group-readable, so the init container reads it through fsGroup
    { name: 'service-token-source', secret: { secretName, defaultMode: 0o440 } },
    { name: 'service-token', emptyDir: { medium: 'Memory', sizeLimit: '1Mi' } },
  ];
}
