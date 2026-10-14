import type { Provider } from '@pulumi/kubernetes';
import { Deployment } from '@pulumi/kubernetes/apps/v1';
import type { DeploymentArgs } from '@pulumi/kubernetes/apps/v1';
import { Namespace, Secret, Service } from '@pulumi/kubernetes/core/v1';
import type { Output } from '@pulumi/pulumi';
import { secret } from '@pulumi/pulumi';
import {
  buildOnePasswordConnectServiceSpec,
  onePasswordConnectServicePort,
} from './build-onepassword-connect-service-spec.ts';
import {
  buildOnePasswordConnectSpec,
  onePasswordConnectCredentialsKey,
} from './build-onepassword-connect-spec.ts';
import { buildServiceURL } from './build-service-url.ts';

// 1Password Connect for imps (GEO-120), following charts/connect in 1Password/connect-helm-charts: the broker swaps a
// placeholder bearer for the real token on op-connect.imp.internal requests, relayed from the host to this ClusterIP
// Service (no public route). Read-only token (vault `imp`), so Connect refuses writes; cluster pods need the bearer too.

export interface OnePasswordConnectInputs {
  // the Connect server's credentials file (JSON)
  readonly credentials: Output<string>;
}

interface OnePasswordConnectOutputs {
  readonly serviceURL: Output<string>;
}

export function createOnePasswordConnect(
  cluster: Provider,
  inputs: OnePasswordConnectInputs,
): OnePasswordConnectOutputs {
  const ns = new Namespace(
    'onepassword',
    { metadata: { name: 'onepassword' } },
    { provider: cluster },
  );

  const namespace = ns.metadata.name;

  createDeployment(
    cluster,
    namespace,
    buildOnePasswordConnectSpec(createCredentials(cluster, namespace, inputs)),
  );

  const service = createService(cluster, namespace);

  return {
    serviceURL: buildServiceURL(
      { name: service.metadata.name, namespace: service.metadata.namespace },
      onePasswordConnectServicePort,
    ),
  };
}

function createDeployment(
  cluster: Provider,
  namespace: Output<string>,
  spec: DeploymentArgs['spec'],
): Deployment {
  return new Deployment(
    'onepassword-connect',
    { metadata: { name: 'onepassword-connect', namespace }, spec },
    { provider: cluster },
  );
}

function createService(cluster: Provider, namespace: Output<string>): Service {
  return new Service(
    'onepassword-connect',
    {
      metadata: { name: 'onepassword-connect', namespace },
      spec: buildOnePasswordConnectServiceSpec(),
    },
    {
      provider: cluster,

      // clusterIP is immutable, so pinning it in a change to the live Service would replace
      // the Service. The state already holds the live value; a new Service takes the pin.
      ignoreChanges: ['spec.clusterIP'],
    },
  );
}

// no fixed name on the Secret: Pulumi names it and replaces it on a change, so the
// Deployment rolls and Connect picks the change up
function createCredentials(
  cluster: Provider,
  namespace: Output<string>,
  inputs: OnePasswordConnectInputs,
): Output<string> {
  const credentials = new Secret(
    'onepassword-connect-credentials',
    {
      metadata: { namespace },
      stringData: { [onePasswordConnectCredentialsKey]: secret(inputs.credentials) },
    },
    { provider: cluster },
  );

  return credentials.metadata.name;
}
