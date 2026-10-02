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
import { atcGatewayLabels, atcGatewayPort, buildATCGatewaySpec } from './build-atc-gateway-spec.ts';
import { createATCGatewayBackupJob } from './create-atc-gateway-backup-job.ts';

// The atc gateway: atc's public MCP origin and OAuth issuer, which dials named
// daemons (docs/plans/atc-gateway.md). Off until the stack config sets atcGateway;
// setting it is an operator step that needs Geoff's approval
// (docs/runbooks/atc-gateway-operator-checklist.md).

export interface ATCGatewayConfig {
  // a digest-pinned image built from deploy/atc-gateway
  readonly image: string;
  readonly backupImage: string;
  readonly publicURL: string;

  // the binary's arguments before --public-url; atc's gateway PR fixes them
  readonly args?: readonly string[];

  // until the gateway serves /healthz and /readyz, the stand-in's metadata path
  readonly livenessPath?: string;
  readonly readinessPath?: string;

  // name → tailnet host:port, non-secret
  readonly daemons?: Readonly<Record<string, string>>;
  readonly defaultDaemon?: string;
}

export interface ATCGatewayBackupSecrets {
  readonly repository: Output<string>;
  readonly password: Output<string>;
  readonly accessKeyID: Output<string>;
  readonly secretAccessKey: Output<string>;
}

interface ATCGatewaySecrets {
  // env var → value, one bearer token per daemon (names come with atc's PR)
  readonly daemonTokens: Readonly<Record<string, Output<string>>>;

  // restic to R2; without it there is no backup CronJob
  readonly backup?: ATCGatewayBackupSecrets;
}

export interface ATCGatewayInputs {
  readonly config: ATCGatewayConfig;
  readonly secrets: ATCGatewaySecrets;
}

interface ATCGatewayOutputs {
  readonly deployment: Deployment;
  readonly backupJob?: CronJob;
  readonly serviceURL: Output<string>;
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
      metadata: { name: 'atc-gateway-daemon-tokens', namespace },
      stringData: inputs.secrets.daemonTokens,
    },
    { provider: cluster },
  );

  const registry = new ConfigMap(
    'atc-gateway-registry',
    {
      metadata: { name: 'atc-gateway-registry', namespace },
      data: {
        'daemons.json': JSON.stringify(inputs.config.daemons ?? {}),
        'default-daemon': inputs.config.defaultDaemon ?? '',
      },
    },
    { provider: cluster },
  );

  return { tokens: tokens.metadata.name, registry: registry.metadata.name };
}
