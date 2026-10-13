// the gateway's resources each take their builder, beside its inputs type
/* oxlint-disable import/max-dependencies */
import type { Provider } from '@pulumi/kubernetes';
import { Deployment } from '@pulumi/kubernetes/apps/v1';
import type { CronJob } from '@pulumi/kubernetes/batch/v1';
import {
  ConfigMap,
  Namespace,
  PersistentVolumeClaim,
  Secret,
  Service,
} from '@pulumi/kubernetes/core/v1';
import { StorageClass } from '@pulumi/kubernetes/storage/v1';
import type { Output } from '@pulumi/pulumi';
import { buildATCGatewayRegistry } from './build-atc-gateway-registry.ts';
import {
  atcGatewayLabels,
  atcGatewayPort,
  atcGatewayRegistryFile,
  buildATCGatewaySpec,
} from './build-atc-gateway-spec.ts';
import { buildATCGatewayTokenData } from './build-atc-gateway-token-data.ts';
import { createATCGatewayBackupJob } from './create-atc-gateway-backup-job.ts';
import type { ATCGatewayInputs } from './inputs/types.ts';

// The atc gateway: atc's public MCP origin and OAuth issuer, which dials named
// daemons (docs/architecture/workloads/atc-gateway.md). Off until the stack config sets
// atcGateway; setting it is an operator step that needs Geoff's approval.

export interface ATCGatewayOutputs {
  readonly deployment: Deployment;
  readonly backupJob?: CronJob;
  readonly serviceURL: Output<string>;

  // the host of the gateway's public URL, which the tunnel routes to serviceURL
  readonly publicHost: string;
}

export function createATCGateway(cluster: Provider, inputs: ATCGatewayInputs): ATCGatewayOutputs {
  const ns = new Namespace('atc', { metadata: { name: 'atc' } }, { provider: cluster });

  const claim = createStateVolume(cluster, ns.metadata.name);
  const objects = createConfigObjects(cluster, ns.metadata.name, inputs);

  const deployment = new Deployment(
    'atc-gateway',
    {
      metadata: { name: 'atc-gateway', namespace: ns.metadata.name },
      spec: buildATCGatewaySpec({ config: inputs.config, claim, ...objects }),
    },
    { provider: cluster },
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

  const backupJob =
    inputs.secrets.backup === undefined
      ? undefined
      : createATCGatewayBackupJob(cluster, {
          namespace: ns.metadata.name,
          claim,
          image: inputs.config.backupImage,
          secrets: inputs.secrets.backup,
        });

  return {
    deployment,
    ...(backupJob === undefined ? {} : { backupJob }),
    serviceURL: service.metadata.apply(
      (meta) => `http://${meta.name}.${meta.namespace}.svc.cluster.local:${atcGatewayPort}`,
    ),
    publicHost: new URL(inputs.config.publicURL).host,
  };
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
): { readonly tokens: Output<string>; readonly registry: Output<string> } {
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

  return { tokens: tokens.metadata.name, registry: registry.metadata.name };
}
