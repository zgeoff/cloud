import { fileURLToPath } from 'node:url';
import type { Provider } from '@pulumi/kubernetes';
import { StatefulSet } from '@pulumi/kubernetes/apps/v1';
import { ConfigMap, Secret, Service } from '@pulumi/kubernetes/core/v1';
import { NetworkPolicy } from '@pulumi/kubernetes/networking/v1';
import type { Output } from '@pulumi/pulumi';
import { all, interpolate } from '@pulumi/pulumi';
import type { BoxxyInputs } from '../inputs/index.ts';
import { createNamespace } from '../shared/create-namespace.ts';
import { readGitSyncImage } from '../shared/read-git-sync-image.ts';
import { readPepysRouteTable } from '../shared/read-pepys-route-table.ts';
import { buildBoxxyNetworkPolicySpec } from './build-boxxy-network-policy-spec.ts';
import { buildBoxxyPepysAddresses } from './build-boxxy-pepys-addresses.ts';
import {
  buildBoxxyOwnerServiceSpec,
  buildBoxxyWorkerServiceSpec,
} from './build-boxxy-service-specs.ts';
import {
  atcTokenKey,
  buildBoxxySpec,
  configFileName,
  githubAppKeys,
  noticeTokenKey,
  pepysSigningSecretKey,
  reviewAppKeys,
  workerTokenKey,
} from './build-boxxy-spec.ts';
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
  doorTunnelToken: Output<string> | undefined,
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
        ...(inputs.secrets.pepysSigningSecret === undefined
          ? {}
          : { [pepysSigningSecretKey]: inputs.secrets.pepysSigningSecret }),
        ...(inputs.secrets.githubApp === undefined
          ? {}
          : {
              [githubAppKeys.BOXXY_GITHUB_APP_CLIENT_ID]: inputs.secrets.githubApp.clientID,
              [githubAppKeys.BOXXY_GITHUB_APP_PRIVATE_KEY]: inputs.secrets.githubApp.privateKey,
              [githubAppKeys.BOXXY_GITHUB_APP_INSTALLATION_ID]:
                inputs.secrets.githubApp.installationID,
            }),
        ...(inputs.secrets.reviewApp === undefined
          ? {}
          : {
              [reviewAppKeys.NOSLOP_GITHUB_APP_ID]: inputs.secrets.reviewApp.appID,
              [reviewAppKeys.NOSLOP_GITHUB_APP_PRIVATE_KEY]: inputs.secrets.reviewApp.privateKey,
              [reviewAppKeys.NOSLOP_GITHUB_APP_INSTALLATION_ID]:
                inputs.secrets.reviewApp.installationID,
            }),
        ...(inputs.secrets.noticeToken === undefined
          ? {}
          : { [noticeTokenKey]: inputs.secrets.noticeToken }),
      },
    },
    { provider: cluster },
  );

  const doorTunnel = createDoorTunnelSecret(cluster, namespace, inputs, doorTunnelToken);
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
            ...(inputs.config.pepys === undefined
              ? {}
              : {
                  pepys: buildBoxxyPepysAddresses(
                    readPepysRouteTable(),
                    inputs.config.pepys.environment,
                  ),
                }),
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
        rulesSyncImage: readGitSyncImage(),
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
        pepysSigningSecret: inputs.secrets.pepysSigningSecret !== undefined,
        githubApp: inputs.secrets.githubApp !== undefined,
        reviewApp: inputs.secrets.reviewApp !== undefined,
        noticeToken: inputs.secrets.noticeToken !== undefined,
        pullSecret: ghcrPullSecretName,
        ...(doorTunnel === undefined ? {} : { doorTunnelToken: doorTunnel.metadata.name }),
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

// No fixed name, so a new token rolls the pod: cloudflared reads it only at start. The program
// makes the door's tunnel exactly when the stack config sets the door, so one without the other is
// a wiring fault.
function createDoorTunnelSecret(
  cluster: Provider,
  namespace: Output<string>,
  inputs: BoxxyInputs,
  doorTunnelToken: Output<string> | undefined,
): Secret | undefined {
  if (inputs.config.publicDoor === undefined) {
    return undefined;
  }

  if (doorTunnelToken === undefined) {
    throw new Error("the boxxy server's public door has no tunnel token");
  }

  return new Secret(
    'boxxy-door-tunnel-token',
    { metadata: { namespace }, stringData: { token: doorTunnelToken } },
    { provider: cluster },
  );
}
