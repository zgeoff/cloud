import type { input } from '@pulumi/kubernetes/types';
import type { Output } from '@pulumi/pulumi';
import { topology } from '@zgeoff/cloud-topology';
import type { ATCGatewayConfig } from '../inputs/index.ts';
import { cloudflaredImage } from '../shared/cloudflared-image.ts';

export const atcGatewayPort = topology.atc.gatewayPort;
export const atcGatewayLabels = { app: 'atc-gateway' };
const nonrootID = 65_532;

// the registry ConfigMap's key, mounted read-only under registryDir
export const atcGatewayRegistryFile = 'registry.json';
const registryDir = '/etc/atc-gateway';

// $HOME/.local/state/atc, until atc's packaging names the gateway's state path
const defaultStateDir = '/home/nonroot/.local/state/atc';

interface GatewaySpecInputs {
  readonly config: ATCGatewayConfig;

  // the host of config.publicURL, which the gateway serves and its probes send as Host
  readonly publicHost: string;
  readonly claim: Output<string>;
  readonly tokens: Output<string>;
  readonly registry: Output<string>;

  // the dockerconfigjson Secret that pulls the private image
  readonly pullSecret: Output<string>;

  // the Secret that holds the atc tunnel's token under the key `token`
  readonly tunnelToken: Output<string>;
}

// The gateway's Deployment spec: `serve` keeps gateway.db/mcp-auth.db in --state-dir and
// reads daemons from --registry; atc writes config under $HOME/.config/atc, sockets in
// $XDG_RUNTIME_DIR. /tmp needs exec for Bun's extracted natives, which an emptyDir allows.
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

    // ATC_GATEWAY_TOKEN_<DAEMON>, which the registry's daemons need
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

// the atc tunnel's token Secret, mounted into the cloudflared sidecar alone
const tunnelTokenDir = '/etc/cloudflared';

// The atc tunnel's connector. It reads the token from a file, never the env, and keeps its
// metrics on loopback, so nothing outside the pod reaches it; that leaves kubelet no port to probe.
function buildTunnelContainer(): input.core.v1.Container {
  return {
    name: 'cloudflared',
    image: cloudflaredImage,
    args: [
      'tunnel',
      '--no-autoupdate',
      '--metrics',
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

// the server answers only its public Host (403 otherwise), so every probe sends it
function buildProbe(path: string, host: string): input.core.v1.Probe {
  return {
    httpGet: { path, port: atcGatewayPort, httpHeaders: [{ name: 'Host', value: host }] },
  };
}
