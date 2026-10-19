import type { Provider } from '@pulumi/kubernetes';
import { Deployment } from '@pulumi/kubernetes/apps/v1';
import type { DeploymentArgs } from '@pulumi/kubernetes/apps/v1';
import { ConfigMap, PersistentVolumeClaim, Secret, Service } from '@pulumi/kubernetes/core/v1';
import { StorageClass } from '@pulumi/kubernetes/storage/v1';
import type { Output } from '@pulumi/pulumi';
import type { ATCGatewayInputs } from '../inputs/index.ts';
import { createNamespace } from '../shared/create-namespace.ts';
import { buildATCGatewayRegistry } from './build-atc-gateway-registry.ts';
import {
  atcGatewayLabels,
  atcGatewayPort,
  atcGatewayRegistryFile,
  buildATCGatewaySpec,
} from './build-atc-gateway-spec.ts';
import { buildATCGatewayTokenData } from './build-atc-gateway-token-data.ts';
import { buildServiceURL } from './build-service-url.ts';
import { createATCGatewayBackupJob } from './create-atc-gateway-backup-job.ts';
import { createGHCRPullSecret } from './create-ghcr-pull-secret.ts';

// The atc gateway: atc's public MCP origin and OAuth issuer, which dials named
// daemons (docs/architecture/workloads/atc-gateway.md). Off until the stack config sets
// atcGateway; setting it is an operator step that needs the owner's approval.

export interface ATCGatewayOutputs {
  readonly serviceURL: Output<string>;

  // the host of the gateway's public URL, which the tunnel routes to serviceURL
  readonly publicHost: string;
}

// tunnelToken is the atc tunnel's token, which the gateway pod's cloudflared sidecar runs with
export function createATCGateway(
  cluster: Provider,
  inputs: ATCGatewayInputs,
  tunnelToken: Output<string>,
): ATCGatewayOutputs {
  const ns = createNamespace('atc', cluster);

  const publicHost = new URL(inputs.config.publicURL).host;

  const claim = createStateVolume(cluster, ns.metadata.name);
  const objects = createConfigObjects(cluster, ns.metadata.name, inputs, tunnelToken);

  createDeployment(
    cluster,
    ns.metadata.name,
    buildATCGatewaySpec({ config: inputs.config, publicHost, claim, ...objects }),
  );

  const service = new Service(
    'atc-gateway',
    {
      metadata: { name: 'atc-gateway', namespace: ns.metadata.name },
      spec: {
        selector: atcGatewayLabels,
        ports: [{ name: 'http', port: atcGatewayPort, targetPort: atcGatewayPort }],
      },
    },
    { provider: cluster },
  );

  if (inputs.secrets.backup !== undefined) {
    createATCGatewayBackupJob(cluster, {
      namespace: ns.metadata.name,
      claim,
      image: inputs.config.backupImage,
      pullSecret: objects.pullSecret,
      secrets: inputs.secrets.backup,
    });
  }

  return {
    serviceURL: buildServiceURL(
      { name: service.metadata.name, namespace: service.metadata.namespace },
      atcGatewayPort,
    ),
    publicHost,
  };
}

function createDeployment(
  cluster: Provider,
  namespace: Output<string>,
  spec: DeploymentArgs['spec'],
): Deployment {
  return new Deployment(
    'atc-gateway',
    { metadata: { name: 'atc-gateway', namespace }, spec },
    { provider: cluster },
  );
}

// local-path's default class deletes the volume with its claim; OAuth state must
// outlive a deleted claim
function createStateVolume(cluster: Provider, namespace: Output<string>): Output<string> {
  const retain = new StorageClass(
    'local-path-retain',
    {
      metadata: { name: 'local-path-retain' },
      provisioner: 'rancher.io/local-path',
      reclaimPolicy: 'Retain',
      volumeBindingMode: 'WaitForFirstConsumer',
    },
    { provider: cluster },
  );

  const claim = new PersistentVolumeClaim(
    'atc-gateway-state',
    {
      metadata: { name: 'atc-gateway-state', namespace },
      spec: {
        storageClassName: retain.metadata.name,
        accessModes: ['ReadWriteOnce'],
        resources: { requests: { storage: '1Gi' } },
      },
    },
    { provider: cluster },
  );

  return claim.metadata.name;
}

function createConfigObjects(
  cluster: Provider,
  namespace: Output<string>,
  inputs: ATCGatewayInputs,
  tunnelToken: Output<string>,
): {
  readonly tokens: Output<string>;
  readonly registry: Output<string>;
  readonly pullSecret: Output<string>;
  readonly tunnelToken: Output<string>;
} {
  const tokens = new Secret(
    'atc-gateway-daemon-tokens',
    {
      // no fixed name: Pulumi names it and replaces it on a change, so the Deployment
      // rolls and the gateway, which reads both only at start, picks the change up
      metadata: { namespace },
      stringData: buildATCGatewayTokenData(inputs.secrets.tokens),
    },
    { provider: cluster },
  );

  const registry = new ConfigMap(
    'atc-gateway-registry',
    {
      metadata: { namespace },
      data: {
        [atcGatewayRegistryFile]: JSON.stringify(
          buildATCGatewayRegistry(inputs.config.daemons, inputs.config.defaultDaemon),
          null,
          2,
        ),
      },
    },
    { provider: cluster },
  );

  const pull = createGHCRPullSecret(cluster, {
    resourceName: 'atc-ghcr-pull',
    namespace,
    credential: inputs.secrets.pullCredential,
  });

  // no fixed name, for the same reason as the daemon tokens: cloudflared reads it only at start
  const tunnel = new Secret(
    'atc-tunnel-token',
    { metadata: { namespace }, stringData: { token: tunnelToken } },
    { provider: cluster },
  );

  return {
    tokens: tokens.metadata.name,
    registry: registry.metadata.name,
    pullSecret: pull.metadata.name,
    tunnelToken: tunnel.metadata.name,
  };
}
