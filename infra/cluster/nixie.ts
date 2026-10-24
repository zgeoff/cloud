import { readFileSync } from 'node:fs';
import { Command } from '@pulumi/command/local';
import type { Provider } from '@pulumi/kubernetes';
import { Deployment, StatefulSet } from '@pulumi/kubernetes/apps/v1';
import { ConfigMap, Secret, Service } from '@pulumi/kubernetes/core/v1';
import type { NetworkPolicy } from '@pulumi/kubernetes/networking/v1';
import type { Output } from '@pulumi/pulumi';
import { interpolate, secret } from '@pulumi/pulumi';
import { topology } from '@zgeoff/cloud-topology';
import type { NixieInputs } from '../inputs/index.ts';
import { buildNixieImpConfig } from '../shared/build-nixie-imp-config.ts';
import { createEgressAllow } from '../shared/create-egress-allow.ts';
import { createNamespace } from '../shared/create-namespace.ts';
import { egressAllows } from '../shared/egress-allows.ts';
import { renderNixieConfig } from '../shared/render-nixie-config.ts';
import { buildNixieSandboxImagesCommandArgs } from './build-nixie-sandbox-images-command-args.ts';
import { buildNixieSandboxImagesJob } from './build-nixie-sandbox-images-job.ts';
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
import {
  buildNixieStatefulSetOptions,
  nixieRolloutTimeouts,
} from './build-nixie-stateful-set-options.ts';
import { buildNixieWebSpec, nixieWebLabels, nixieWebPort } from './build-nixie-web-spec.ts';
import { createNixieBackupJob } from './create-nixie-backup-job.ts';
import type { NixieIngressOutputs } from './create-nixie-ingress.ts';
import { createNixieIngress } from './create-nixie-ingress.ts';

interface NixieClusterShape {
  readonly zoneID: Output<string>;
  readonly kubeconfig: Output<string>;
}

export function createNixie(
  cluster: Provider,
  inputs: NixieInputs,
  shape: NixieClusterShape,
): NixieIngressOutputs {
  const ns = createNamespace('nixie', cluster);
  const namespace = ns.metadata.name;

  createEgressAllow(egressAllows.nixie, namespace, { provider: cluster });

  const api = createService(cluster, namespace, {
    name: 'nixie',
    labels: nixieLabels,
    port: nixieAPIPort,
  });

  const secrets = createSecrets(cluster, namespace, inputs);

  const sandboxImages = createSandboxImagesCommand({
    image: inputs.config.image,
    secrets,
    egressAllow: createEgressAllow(egressAllows.nixieSandboxImages, namespace, {
      provider: cluster,
    }),
    kubeconfig: shape.kubeconfig,
  });

  const statefulSet = createStatefulSet(cluster, namespace, {
    inputs,
    serviceName: api.metadata.name,
    secret: secrets.metadata.name,
    sandboxImages,
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
    zoneID: shape.zoneID,
    api: { service: api.metadata.name, port: nixieAPIPort },
    web: { service: webService.metadata.name, port: nixieWebPort },
  });

  if (inputs.backup !== undefined) {
    createNixieBackupJob(cluster, { namespace, statefulSet, backup: inputs.backup });
  }

  return ingress;
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

const deployDir = new URL('../../deploy/nixie/', import.meta.url);

function createSecrets(cluster: Provider, namespace: Output<string>, inputs: NixieInputs): Secret {
  return new Secret(
    'nixie-secrets',
    {
      metadata: { namespace },
      stringData: {
        // the sops file is encrypted already; the age identity beside it is the secret
        [nixieSecretsFileKey]: readFileSync(new URL('secrets.sops.yaml', deployDir), 'utf8'),
        [nixieAgeKeyKey]: secret(inputs.secrets.ageHostKey),
      },
    },
    { provider: cluster },
  );
}

interface SandboxImagesShape {
  readonly image: string;
  readonly secrets: Secret;
  readonly egressAllow: NetworkPolicy;
  readonly kubeconfig: Output<string>;
}

// nixie adds its sandbox images at start and is unready until impd holds them, so the Job adds them
// while the old nixie-0 still serves; a failed Job fails this Command, and Pulumi then leaves the
// StatefulSet unchanged
function createSandboxImagesCommand(shape: SandboxImagesShape): Command {
  const job = shape.secrets.metadata.name.apply((name) =>
    JSON.stringify(buildNixieSandboxImagesJob({ image: shape.image, secret: name })),
  );

  return new Command(
    'nixie-sandbox-images',
    buildNixieSandboxImagesCommandArgs({ job, kubeconfig: shape.kubeconfig }),
    { dependsOn: [shape.secrets, shape.egressAllow] },
  );
}

interface StatefulSetShape {
  readonly inputs: NixieInputs;
  readonly serviceName: Output<string>;
  readonly secret: Output<string>;
  readonly sandboxImages: Command;
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
        secret: shape.secret,
        definitionsSecret: createDefinitionsKey(cluster, namespace, shape.inputs),
      }),
    },
    buildNixieStatefulSetOptions({ cluster, sandboxImages: shape.sandboxImages }),
  );
}

function createConfig(cluster: Provider, namespace: Output<string>): Output<string> {
  const text = readFileSync(new URL('config.yaml', deployDir), 'utf8');

  const config = new ConfigMap(
    'nixie-config',
    {
      // No fixed name, as on the Secrets: Pulumi replaces each on a change, so the StatefulSet
      // rolls and nixie reads the change at its next start.
      metadata: { namespace },
      data: { [nixieConfigKey]: renderNixieConfig(text, buildNixieImpConfig(topology)) },
    },
    { provider: cluster },
  );

  return config.metadata.name;
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

interface WebShape {
  readonly image: string;
  readonly api: Output<string>;
  readonly statefulSet: StatefulSet;
}

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

    // after nixie, so a first deploy starts the API before the client that calls it
    { provider: cluster, dependsOn: [shape.statefulSet], customTimeouts: nixieRolloutTimeouts },
  );
}
