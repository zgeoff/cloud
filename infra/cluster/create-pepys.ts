import { readFileSync } from 'node:fs';
import type { Provider } from '@pulumi/kubernetes';
import { Deployment, StatefulSet } from '@pulumi/kubernetes/apps/v1';
import { ConfigMap, PersistentVolumeClaim, Secret, Service } from '@pulumi/kubernetes/core/v1';
import { NetworkPolicy } from '@pulumi/kubernetes/networking/v1';
import type { Output } from '@pulumi/pulumi';
import type { PepysInputs } from '../inputs/index.ts';
import { buildPepysEgressPolicySpecs } from '../shared/build-pepys-egress-policy-specs.ts';
import { createNamespace } from '../shared/create-namespace.ts';
import { pepysImages } from '../shared/pepys-images.ts';
import { pepysWorkloads } from '../shared/pepys-workloads.ts';
import { readPepysRouteTable } from '../shared/read-pepys-route-table.ts';
import { ghcrPullSecretName } from './build-ghcr-pull-secret-args.ts';
import { buildPepysGarageSpec } from './build-pepys-garage-spec.ts';
import { buildPepysHostSpec } from './build-pepys-host-spec.ts';
import { buildPepysIngestSpec } from './build-pepys-ingest-spec.ts';
import { buildPepysNetworkPolicySpecs } from './build-pepys-network-policy-specs.ts';
import { buildPepysPublicPath } from './build-pepys-public-path.ts';
import { buildPepysS2Spec } from './build-pepys-s2-spec.ts';
import { createGHCRPullSecret } from './create-ghcr-pull-secret.ts';
import { createPepysBackupJob } from './create-pepys-backup-job.ts';
import { readPepysIssuerDocuments } from './read-pepys-issuer-documents.ts';

// the routes of ingest that the shared tunnel carries, by one anchored path pattern
export interface PepysRoute {
  readonly hostname: string;
  readonly service: string;
  readonly path: string;
}

// the API's /mcp and OAuth paths, which the shared tunnel carries with Access on the browser paths
export interface PepysAPIRoute {
  readonly hostname: string;

  // resolves once the host's StatefulSet has rolled out, so the tunnel's rules wait for it
  readonly service: Output<string>;
}

interface PepysOutputs {
  // unset while no route of the deployment is public
  readonly route?: PepysRoute;

  // unset while stack config "pepys.apiHostname" is unset
  readonly apiRoute?: PepysAPIRoute;
}

export function createPepys(cluster: Provider, inputs: PepysInputs): PepysOutputs {
  const ns = createNamespace('pepys', cluster);
  const namespace = ns.metadata.name;

  const pull = createGHCRPullSecret(cluster, {
    resourceName: 'pepys-ghcr-pull',
    namespace,
    credential: inputs.pullCredential,
  });

  const apiHostname = inputs.config.apiHostname;

  createNetworkPolicies(cluster, namespace, apiHostname !== undefined);
  createGarage(cluster, namespace, inputs);
  createS2(cluster, namespace, inputs);
  createIngest(cluster, namespace, inputs, pull);

  const host = createHost(cluster, namespace, inputs, pull);

  if (inputs.backup !== undefined) {
    createPepysBackupJob(cluster, namespace, inputs.backup);
  }

  const path = buildPepysPublicPath(readPepysRouteTable());

  return {
    ...(path === undefined
      ? {}
      : {
          route: {
            hostname: inputs.config.webhookHostname,
            service: pepysWorkloads.ingest.url,
            path,
          },
        }),
    ...(apiHostname === undefined
      ? {}
      : {
          apiRoute: {
            hostname: apiHostname,

            // an older API serves /mcp to any caller, so the route waits until the pod that runs
            // the pinned image is ready
            service: host.metadata.name.apply(() => pepysWorkloads.host.url),
          },
        }),
  };
}

// each pod's ingress policy and its egress policy, beside the namespace's deny of all egress
function createNetworkPolicies(
  cluster: Provider,
  namespace: Output<string>,
  isAPIPublic: boolean,
): NetworkPolicy[] {
  const specs = { ...buildPepysNetworkPolicySpecs(isAPIPublic), ...buildPepysEgressPolicySpecs() };

  return Object.entries(specs).map(
    ([name, spec]) =>
      new NetworkPolicy(name, { metadata: { name, namespace }, spec }, { provider: cluster }),
  );
}

function createGarage(
  cluster: Provider,
  namespace: Output<string>,
  inputs: PepysInputs,
): StatefulSet {
  const garage = pepysWorkloads.garage;
  const service = createService(cluster, namespace, garage, garage.s3Port);

  const env = createEnvSecret(cluster, namespace, garage.name, {
    GARAGE_RPC_SECRET: inputs.secrets.garageRPCSecret,
    GARAGE_ADMIN_TOKEN: inputs.secrets.garageAdminToken,
    GARAGE_DEFAULT_ACCESS_KEY: inputs.secrets.s2GarageAccessKeyID,
    GARAGE_DEFAULT_SECRET_KEY: inputs.secrets.s2GarageSecretAccessKey,
  });

  const config = new ConfigMap(
    `${garage.name}-config`,
    {
      metadata: { namespace },
      data: {
        'garage.toml': readFileSync(
          new URL('../../deploy/pepys/garage.toml', import.meta.url),
          'utf8',
        ),
      },
    },
    { provider: cluster },
  );

  return new StatefulSet(
    garage.name,
    {
      metadata: { name: garage.name, namespace },
      spec: buildPepysGarageSpec({
        image: pepysImages.garageImage,
        serviceName: service.metadata.name,
        configMap: config.metadata.name,
        envSecret: env.metadata.name,
      }),
    },
    { provider: cluster },
  );
}

interface PepysWorkload {
  readonly name: string;
  readonly labels: Readonly<Record<string, string>>;

  // a pinned address, for a Service that something outside the cluster dials
  readonly clusterIP?: string;
}

// Pulumi skips its wait for ready pods on each Service: the workload updates after the Service it
// names, so that wait would hold back the rollout that brings them.
function createService(
  cluster: Provider,
  namespace: Output<string>,
  workload: PepysWorkload,
  port: number,
): Service {
  return new Service(
    workload.name,
    {
      metadata: {
        name: workload.name,
        namespace,
        annotations: { 'pulumi.com/skipAwait': 'true' },
      },
      spec: {
        ...(workload.clusterIP === undefined ? {} : { clusterIP: workload.clusterIP }),
        selector: workload.labels,
        ports: [{ name: 'http', port, targetPort: port }],
      },
    },
    { provider: cluster },
  );
}

// Pulumi names each Secret, so a changed value replaces it and rolls the workload that reads it
function createEnvSecret(
  cluster: Provider,
  namespace: Output<string>,
  name: string,
  stringData: Readonly<Record<string, Output<string>>>,
): Secret {
  return new Secret(name, { metadata: { namespace }, stringData }, { provider: cluster });
}

function createS2(cluster: Provider, namespace: Output<string>, inputs: PepysInputs): Deployment {
  const s2 = pepysWorkloads.s2;

  createService(cluster, namespace, s2, s2.port);

  const env = createEnvSecret(cluster, namespace, s2.name, {
    AWS_ACCESS_KEY_ID: inputs.secrets.s2GarageAccessKeyID,
    AWS_SECRET_ACCESS_KEY: inputs.secrets.s2GarageSecretAccessKey,
  });

  return new Deployment(
    s2.name,
    {
      metadata: { name: s2.name, namespace },
      spec: buildPepysS2Spec({ image: pepysImages.s2Image, envSecret: env.metadata.name }),
    },
    { provider: cluster },
  );
}

function createIngest(
  cluster: Provider,
  namespace: Output<string>,
  inputs: PepysInputs,
  pull: Secret,
): Deployment {
  const ingest = pepysWorkloads.ingest;

  createService(cluster, namespace, ingest, ingest.port);

  const env = createEnvSecret(cluster, namespace, ingest.name, {
    PEPYS_S2_ACCESS_TOKEN: inputs.secrets.s2AccessToken,
    ...inputs.secrets.ingest,
  });

  const issuers = new ConfigMap(
    'pepys-imp-issuers',
    { metadata: { namespace }, data: readPepysIssuerDocuments() },
    { provider: cluster },
  );

  return new Deployment(
    ingest.name,
    {
      metadata: { name: ingest.name, namespace },
      spec: buildPepysIngestSpec({
        image: inputs.config.image,
        ...(inputs.config.impIdentityAudience === undefined
          ? {}
          : { impIdentityAudience: inputs.config.impIdentityAudience }),
        envSecret: env.metadata.name,
        issuersConfigMap: issuers.metadata.name,
        pullSecret: ghcrPullSecretName,
      }),
    },
    { provider: cluster, dependsOn: [pull] },
  );
}

function createHost(
  cluster: Provider,
  namespace: Output<string>,
  inputs: PepysInputs,
  pull: Secret,
): StatefulSet {
  const host = pepysWorkloads.host;
  const service = createService(cluster, namespace, host, host.apiPort);

  const env = createEnvSecret(cluster, namespace, host.name, {
    PEPYS_S2_ACCESS_TOKEN: inputs.secrets.s2AccessToken,
  });

  const apiHostname = inputs.config.apiHostname;

  const mcp =
    apiHostname === undefined
      ? undefined
      : {
          publicURL: `https://${apiHostname}`,
          authClaim: createAuthClaim(cluster, namespace),
        };

  return new StatefulSet(
    host.name,
    {
      metadata: { name: host.name, namespace },
      spec: buildPepysHostSpec({
        image: inputs.config.image,
        serviceName: service.metadata.name,
        envSecret: env.metadata.name,
        pullSecret: ghcrPullSecretName,
        ...(mcp === undefined ? {} : { mcp }),
      }),
    },
    { provider: cluster, dependsOn: [pull] },
  );
}

// A claim of its own beside the StatefulSet: a live StatefulSet refuses a new claim template, so
// one would replace the host. The retaining class keeps the OAuth server's database when the claim
// goes, since losing it signs every client out.
function createAuthClaim(cluster: Provider, namespace: Output<string>): Output<string> {
  const claim = new PersistentVolumeClaim(
    'pepys-auth',
    {
      metadata: { name: 'pepys-auth', namespace },
      spec: {
        storageClassName: 'local-path-retain',
        accessModes: ['ReadWriteOnce'],
        resources: { requests: { storage: '1Gi' } },
      },
    },
    { provider: cluster },
  );

  return claim.metadata.name;
}
