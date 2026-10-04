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
import { atcGatewayTokenVariable, buildATCGatewayRegistry } from './build-atc-gateway-registry.ts';
import {
  atcGatewayLabels,
  atcGatewayPort,
  atcGatewayRegistryFile,
  buildATCGatewaySpec,
} from './build-atc-gateway-spec.ts';
import { createATCGatewayBackupJob } from './create-atc-gateway-backup-job.ts';

// The atc gateway: atc's public MCP origin and OAuth issuer, which dials named
// daemons (docs/plans/atc-gateway.md). Off until the stack config sets atcGateway;
// setting it is an operator step that needs Geoff's approval
// (docs/runbooks/atc-gateway-operator-checklist.md).

export interface ATCGatewayConfig {
  // a digest-pinned image built from deploy/atc-gateway
  readonly image: string;
  readonly backupImage: string;

  // the origin clients reach, and the OAuth issuer
  readonly publicURL: string;

  // geoffcloud's daemon: its tailnet host:port and the daemonID `atc daemon id`
  // prints there. Both are required; the deploy refuses without them.
  readonly daemonAddress?: string;
  readonly daemonID?: string;

  // where the state volume mounts and --state-dir points: gateway.db and
  // mcp-auth.db. atc's packaging fixes the path; the default is $HOME's state dir.
  readonly stateDir?: string;
}

export interface ATCGatewayBackupSecrets {
  readonly repository: Output<string>;
  readonly password: Output<string>;
  readonly accessKeyID: Output<string>;
  readonly secretAccessKey: Output<string>;
}

interface ATCGatewaySecrets {
  // the bearer token the gateway presents to geoffcloud's daemon
  readonly token: Output<string>;

  // restic to R2; without it there is no backup CronJob
  readonly backup?: ATCGatewayBackupSecrets;
}

// the daemon as the registry pins it, checked
interface ATCGatewayDaemon {
  readonly address: string;
  readonly daemonID: string;
}

export interface ATCGatewayInputs {
  readonly config: ATCGatewayConfig;
  readonly daemon: ATCGatewayDaemon;
  readonly secrets: ATCGatewaySecrets;
}

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
      stringData: { [atcGatewayTokenVariable]: inputs.secrets.token },
    },
    { provider: cluster },
  );

  const registry = new ConfigMap(
    'atc-gateway-registry',
    {
      metadata: { namespace },
      data: {
        [atcGatewayRegistryFile]: JSON.stringify(buildATCGatewayRegistry(inputs.daemon), null, 2),
      },
    },
    { provider: cluster },
  );

  return { tokens: tokens.metadata.name, registry: registry.metadata.name };
}
