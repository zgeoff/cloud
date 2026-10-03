import type { input } from '@pulumi/kubernetes/types';
import type { Output } from '@pulumi/pulumi';
import type { ATCGatewayConfig } from './atc-gateway.ts';

export const atcGatewayPort = 8414;
export const atcGatewayLabels = { app: 'atc-gateway' };
const nonrootID = 65_532;

// the registry ConfigMap's key, mounted read-only under registryDir
export const atcGatewayRegistryFile = 'registry.json';
const registryDir = '/etc/atc-gateway';

// $HOME/.local/state/atc, until atc's packaging names the gateway's state path
const defaultStateDir = '/home/nonroot/.local/state/atc';

interface GatewaySpecInputs {
  readonly config: ATCGatewayConfig;
  readonly claim: Output<string>;
  readonly tokens: Output<string>;
  readonly registry: Output<string>;
}

// The gateway's Deployment spec. `atc-gateway serve` keeps gateway.db and
// mcp-auth.db in --state-dir (the volume) and reads the daemons from --registry;
// atc writes its config under $HOME/.config/atc and its sockets in $XDG_RUNTIME_DIR. A Bun
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
      ...buildProbe('/healthz', publicHost),
      periodSeconds: 20,
      failureThreshold: 3,
    },
    readinessProbe: { ...buildProbe('/readyz', publicHost), periodSeconds: 10 },
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
