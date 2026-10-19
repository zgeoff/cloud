import { readFileSync } from 'node:fs';
import type { Provider } from '@pulumi/kubernetes';
import { Deployment, StatefulSet } from '@pulumi/kubernetes/apps/v1';
import { ConfigMap, Secret, Service } from '@pulumi/kubernetes/core/v1';
import type { Output } from '@pulumi/pulumi';
import { interpolate, secret } from '@pulumi/pulumi';
import { topology } from '@zgeoff/cloud-topology';
import type { NixieInputs } from '../inputs/index.ts';
import { buildNixieImpConfig } from '../shared/build-nixie-imp-config.ts';
import { createNamespace } from '../shared/create-namespace.ts';
import { renderNixieConfig } from '../shared/render-nixie-config.ts';
import { buildNixieServiceArgs } from './build-nixie-service-args.ts';
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

export function createNixie(
  cluster: Provider,
  inputs: NixieInputs,
  zoneID: Output<string>,
): NixieIngressOutputs {
  const ns = createNamespace('nixie', cluster);
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

  createWebDeployment(cluster, namespace, {
    image: inputs.config.webImage,
    api: api.metadata.name,
    statefulSet,
  });

  const ingress = createNixieIngress(cluster, {
    namespace,
    hostname: inputs.config.hostname,
    dnsToken: inputs.secrets.dnsToken,
    zoneID,
    api: { service: api.metadata.name, port: nixieAPIPort },
    web: { service: webService.metadata.name, port: nixieWebPort },
  });

  if (inputs.backup !== undefined) {
    createNixieBackupJob(cluster, { namespace, statefulSet, backup: inputs.backup });
  }

  return ingress;
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
  return new Service(shape.name, buildNixieServiceArgs({ ...shape, namespace }), {
    provider: cluster,
  });
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

const deployDir = new URL('../../deploy/nixie/', import.meta.url);

// The ConfigMap and the Secrets have no fixed name: Pulumi names each and replaces it on a change,
// so the StatefulSet rolls and nixie reads the change at its next start.
function createConfig(cluster: Provider, namespace: Output<string>): Output<string> {
  const text = readFileSync(new URL('config.yaml', deployDir), 'utf8');

  const config = new ConfigMap(
    'nixie-config',
    {
      metadata: { namespace },
      data: { [nixieConfigKey]: renderNixieConfig(text, buildNixieImpConfig(topology)) },
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
