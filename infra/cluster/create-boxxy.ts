import { fileURLToPath } from 'node:url';
import type { Provider } from '@pulumi/kubernetes';
import { StatefulSet } from '@pulumi/kubernetes/apps/v1';
import { ConfigMap, Secret, Service } from '@pulumi/kubernetes/core/v1';
import { NetworkPolicy } from '@pulumi/kubernetes/networking/v1';
import type { Output } from '@pulumi/pulumi';
import { all, interpolate } from '@pulumi/pulumi';
import type { BoxxyInputs } from '../inputs/index.ts';
import { createNamespace } from '../shared/create-namespace.ts';
import { buildBoxxyNetworkPolicySpec } from './build-boxxy-network-policy-spec.ts';
import {
  buildBoxxyOwnerServiceSpec,
  buildBoxxyWorkerServiceSpec,
} from './build-boxxy-service-specs.ts';
import { atcTokenKey, buildBoxxySpec, configFileName, workerTokenKey } from './build-boxxy-spec.ts';
import { ghcrPullSecretName } from './build-ghcr-pull-secret-args.ts';
import { createBoxxyBackupJob } from './create-boxxy-backup-job.ts';
import { createGHCRPullSecret } from './create-ghcr-pull-secret.ts';
import { readBoxxyTrustDocuments } from './read-boxxy-trust-documents.ts';
import { boxxyOwnerPort, renderBoxxyConfig } from './render-boxxy-config.ts';

// the trust documents, one `<issuer>.json` per impd host, as `impz identity jwks` prints them
const trustDocumentsFolder = fileURLToPath(new URL('../../deploy/boxxy/issuers', import.meta.url));

interface BoxxyOutputs {
  // the owner listener in the cluster, for the tailnet route
  readonly ownerServiceURL: Output<string>;
}

// the atc gateway's MCP route, under its in-cluster Service URL
const atcRoute = '/mcp';

// the gateway answers only requests whose Host is its public host, so the server sends that Host
// on each call to the in-cluster Service
interface BoxxyATCGateway {
  readonly serviceURL: Output<string>;
  readonly publicHost: string;
}

export function createBoxxy(
  cluster: Provider,
  inputs: BoxxyInputs,
  atcGateway: BoxxyATCGateway,
): BoxxyOutputs {
  const ns = createNamespace('boxxy', cluster);
  const namespace = ns.metadata.name;

  const pull = createGHCRPullSecret(cluster, {
    resourceName: 'boxxy-ghcr-pull',
    namespace,
    credential: inputs.pullCredential,
  });

  // Pulumi names the Secret and the ConfigMaps and replaces each when its data changes, so a new
  // token, configuration or trust document rolls the pod
  const tokens = new Secret(
    'boxxy-tokens',
    {
      metadata: { namespace },
      stringData: {
        [workerTokenKey]: inputs.secrets.workerToken,
        [atcTokenKey]: inputs.secrets.atcToken,
      },
    },
    { provider: cluster },
  );

  const trustDocuments = readBoxxyTrustDocuments(trustDocumentsFolder);
  const trusted = Object.keys(trustDocuments).length > 0;

  const issuers = trusted
    ? new ConfigMap(
        'boxxy-issuers',
        { metadata: { namespace }, data: trustDocuments },
        { provider: cluster },
      )
    : undefined;

  const config = new ConfigMap(
    'boxxy-config',
    {
      metadata: { namespace },
      data: {
        // the repos are a secret, so the file is one: Pulumi hides the data in every preview
        [configFileName]: all([atcGateway.serviceURL, inputs.repos]).apply(([serviceURL, repos]) =>
          renderBoxxyConfig({
            config: inputs.config,
            repos,
            atc: { url: `${serviceURL}${atcRoute}`, host: atcGateway.publicHost },
            trusted,
          }),
        ),
      },
    },
    { provider: cluster },
  );

  // Pulumi skips its wait for ready pods: the StatefulSet updates after the Service it names, so
  // that wait would hold back the rollout that brings them
  const owner = new Service(
    'boxxy',
    {
      metadata: {
        name: 'boxxy',
        namespace,
        annotations: { 'pulumi.com/skipAwait': 'true' },
      },
      spec: buildBoxxyOwnerServiceSpec(),
    },
    { provider: cluster },
  );

  const worker = new Service(
    'boxxy-worker',
    {
      metadata: {
        name: 'boxxy-worker',
        namespace,
        annotations: { 'pulumi.com/skipAwait': 'true' },
      },
      spec: buildBoxxyWorkerServiceSpec(),
    },
    {
      provider: cluster,

      // clusterIP is immutable, so pinning it in a change to the live Service would replace the
      // Service. The state already holds the live value; a new Service takes the pin.
      ignoreChanges: ['spec.clusterIP'],
    },
  );

  // the pod starts only once its ingress policy holds
  const ingress = new NetworkPolicy(
    'boxxy-server',
    {
      metadata: { name: 'boxxy-server', namespace },
      spec: buildBoxxyNetworkPolicySpec(),
    },
    { provider: cluster },
  );

  const statefulSet = new StatefulSet(
    'boxxy',
    {
      metadata: { name: 'boxxy', namespace },
      spec: buildBoxxySpec({
        image: inputs.config.image,
        serviceName: owner.metadata.name,
        configMap: config.metadata.name,
        ...(issuers === undefined
          ? {}
          : {
              trustDocuments: {
                configMap: issuers.metadata.name,
                files: Object.keys(trustDocuments).toSorted(),
              },
            }),
        tokenSecret: tokens.metadata.name,
        pullSecret: ghcrPullSecretName,
      }),
    },
    { provider: cluster, dependsOn: [pull, worker, ingress] },
  );

  if (inputs.backup !== undefined) {
    createBoxxyBackupJob(cluster, {
      namespace,
      statefulSet,
      backup: inputs.backup,
    });
  }

  return {
    ownerServiceURL: interpolate`http://${owner.metadata.name}.${namespace}.svc.cluster.local:${boxxyOwnerPort}`,
  };
}
