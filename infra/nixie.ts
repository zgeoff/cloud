import { readFileSync } from 'node:fs';
import type { Provider } from '@pulumi/kubernetes';
import { Deployment, StatefulSet } from '@pulumi/kubernetes/apps/v1';
import type { CronJob } from '@pulumi/kubernetes/batch/v1';
import { ConfigMap, Namespace, Secret, Service } from '@pulumi/kubernetes/core/v1';
import type { Output } from '@pulumi/pulumi';
import { interpolate, secret } from '@pulumi/pulumi';
import {
  buildNixieSpec,
  definitionsDeployKeyKey,
  definitionsKnownHostsKey,
  githubKnownHosts,
  nixieAPIPort,
  nixieAgeKeyKey,
  nixieConfigKey,
  nixieLabels,
  nixieSecretsFileKey,
} from './build-nixie-spec.ts';
import { buildNixieWebSpec, nixieWebLabels, nixieWebPort } from './build-nixie-web-spec.ts';
import { createNixieBackupJob } from './create-nixie-backup-job.ts';
import type { NixieIngressOutputs } from './create-nixie-ingress.ts';
import { createNixieIngress } from './create-nixie-ingress.ts';

// nixie (GEO-343): nixie's server with a git-sync sidecar, its web client, and an ingress on the
// host's tailnet address only. nixie reaches impd at imps.geoff.cloud through the host's node
// (tag:cloud). docs/architecture/workloads/nixie.md describes the whole.

// the stack config's nixie object; setting it approves the deploy
export interface NixieConfig {
  // the nixie and nixie-web images of one release, each by tag and digest
  readonly image: string;
  readonly webImage: string;

  // the one public DNS name, which points at the host's tailnet address
  readonly hostname: string;
}

// a nightly restic backup of nixie.db and keys.db to nixie's own R2 bucket
export interface NixieBackupInputs {
  readonly image: string;
  readonly secrets: {
    readonly repository: Output<string>;
    readonly password: Output<string>;
    readonly accessKeyID: Output<string>;
    readonly secretAccessKey: Output<string>;
  };
}

export interface NixieInputs {
  readonly config: NixieConfig;
  readonly secrets: {
    // the host's age identity, which decrypts deploy/nixie/secrets.sops.yaml
    readonly ageHostKey: Output<string>;

    // git-sync's read-only deploy key for zgeoff/nixie-definitions
    readonly definitionsDeployKey: Output<string>;

    // Pulumi's own Cloudflare token, for the certificate's DNS-01 challenge
    readonly dnsToken: Output<string>;
  };

  // without it there is no backup CronJob
  readonly backup?: NixieBackupInputs;
}

export interface NixieOutputs extends NixieIngressOutputs {
  readonly statefulSet: StatefulSet;
  readonly web: Deployment;
  readonly backupJob?: CronJob;
}

export function createNixie(
  cluster: Provider,
  inputs: NixieInputs,
  zoneID: Output<string>,
): NixieOutputs {
  const ns = new Namespace('nixie', { metadata: { name: 'nixie' } }, { provider: cluster });

  const namespace = ns.metadata.name;

  const api = createService(cluster, namespace, {
    name: 'nixie',
    labels: nixieLabels,
    port: nixieAPIPort,
  });

  const statefulSet = createStatefulSet(cluster, namespace, {
    inputs,
    serviceName: api.metadata.name,
  });

  const webService = createService(cluster, namespace, {
    name: 'nixie-web',
    labels: nixieWebLabels,
    port: nixieWebPort,
  });

  const web = createWebDeployment(cluster, namespace, {
    image: inputs.config.webImage,
    api: api.metadata.name,
    statefulSet,
  });

  const ingress = createNixieIngress(cluster, {
    namespace,
    namespaceResource: ns,
    hostname: inputs.config.hostname,
    dnsToken: inputs.secrets.dnsToken,
    zoneID,
    api: { service: api.metadata.name, port: nixieAPIPort },
    web: { service: webService.metadata.name, port: nixieWebPort },
  });

  const backupJob =
    inputs.backup === undefined
      ? undefined
      : createNixieBackupJob(cluster, { namespace, statefulSet, backup: inputs.backup });

  return { statefulSet, web, ...ingress, ...(backupJob === undefined ? {} : { backupJob }) };
}

// Pulumi waits for readiness, and nixie turns ready only once impd has pulled its sandbox images
// and booted the conversation imp, which a cold start takes longer than Pulumi's default wait for
const rolloutTimeouts = { create: '30m', update: '30m' };

interface WebShape {
  readonly image: string;
  readonly api: Output<string>;
  readonly statefulSet: StatefulSet;
}

// after nixie, so a first deploy starts the API before the client that calls it
function createWebDeployment(
  cluster: Provider,
  namespace: Output<string>,
  shape: WebShape,
): Deployment {
  return new Deployment(
    'nixie-web',
    {
      metadata: { name: 'nixie-web', namespace },
      spec: buildNixieWebSpec({
        image: shape.image,
        apiURL: interpolate`http://${shape.api}.${namespace}.svc.cluster.local:${nixieAPIPort}`,
      }),
    },
    { provider: cluster, dependsOn: [shape.statefulSet], customTimeouts: rolloutTimeouts },
  );
}

interface ServiceShape {
  readonly name: string;
  readonly labels: Record<string, string>;
  readonly port: number;
}

function createService(cluster: Provider, namespace: Output<string>, shape: ServiceShape): Service {
  return new Service(
    shape.name,
    {
      metadata: { name: shape.name, namespace },
      spec: {
        selector: shape.labels,
        ports: [{ name: 'http', port: shape.port, targetPort: 'http' }],
      },
    },
    { provider: cluster },
  );
}

interface StatefulSetShape {
  readonly inputs: NixieInputs;
  readonly serviceName: Output<string>;
}

function createStatefulSet(
  cluster: Provider,
  namespace: Output<string>,
  shape: StatefulSetShape,
): StatefulSet {
  return new StatefulSet(
    'nixie',
    {
      metadata: { name: 'nixie', namespace },
      spec: buildNixieSpec({
        image: shape.inputs.config.image,
        serviceName: shape.serviceName,
        configMap: createConfig(cluster, namespace),
        secret: createSecrets(cluster, namespace, shape.inputs),
        definitionsSecret: createDefinitionsKey(cluster, namespace, shape.inputs),
      }),
    },
    { provider: cluster, customTimeouts: rolloutTimeouts },
  );
}

const deployDir = new URL('../deploy/nixie/', import.meta.url);

// The ConfigMap and the Secrets have no fixed name: Pulumi names each and replaces it on a change,
// so the StatefulSet rolls and nixie reads the change at its next start.
function createConfig(cluster: Provider, namespace: Output<string>): Output<string> {
  const config = new ConfigMap(
    'nixie-config',
    {
      metadata: { namespace },
      data: { [nixieConfigKey]: readFileSync(new URL('config.yaml', deployDir), 'utf8') },
    },
    { provider: cluster },
  );

  return config.metadata.name;
}

// the sops file is encrypted already; the age identity beside it is the secret
function createSecrets(
  cluster: Provider,
  namespace: Output<string>,
  inputs: NixieInputs,
): Output<string> {
  const secrets = new Secret(
    'nixie-secrets',
    {
      metadata: { namespace },
      stringData: {
        [nixieSecretsFileKey]: readFileSync(new URL('secrets.sops.yaml', deployDir), 'utf8'),
        [nixieAgeKeyKey]: secret(inputs.secrets.ageHostKey),
      },
    },
    { provider: cluster },
  );

  return secrets.metadata.name;
}

function createDefinitionsKey(
  cluster: Provider,
  namespace: Output<string>,
  inputs: NixieInputs,
): Output<string> {
  const key = new Secret(
    'nixie-definitions-key',
    {
      metadata: { namespace },
      stringData: {
        // OpenSSH refuses a private key without its final newline
        [definitionsDeployKeyKey]: secret(inputs.secrets.definitionsDeployKey).apply(
          (value) => `${value.trimEnd()}\n`,
        ),
        [definitionsKnownHostsKey]: githubKnownHosts,
      },
    },
    { provider: cluster },
  );

  return key.metadata.name;
}
