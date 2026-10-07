import type { Provider } from '@pulumi/kubernetes';
import { Deployment } from '@pulumi/kubernetes/apps/v1';
import { Namespace, Secret, Service } from '@pulumi/kubernetes/core/v1';
import type { Output } from '@pulumi/pulumi';
import { all, secret } from '@pulumi/pulumi';
import {
  buildOnePasswordConnectServiceSpec,
  onePasswordConnectServicePort,
} from './build-onepassword-connect-service-spec.ts';
import {
  buildOnePasswordConnectSpec,
  onePasswordConnectCredentialsKey,
} from './build-onepassword-connect-spec.ts';

// 1Password Connect, for imps (GEO-120): imp's credential broker swaps a placeholder
// bearer for the real Connect token on requests to op-connect.imp.internal and forwards
// them to a relay on the host, which dials this Service's ClusterIP. Connect has no public
// route. The pod follows 1Password's Helm chart (charts/connect in
// 1Password/connect-helm-charts). The token is read-only (vault `imp`, read), so Connect
// itself refuses a write. Pods in the cluster can reach the Service too; they need the
// bearer token either way.

export interface OnePasswordConnectInputs {
  // the Connect server's credentials file (JSON)
  readonly credentials: Output<string>;
}

export interface OnePasswordConnectOutputs {
  readonly deployment: Deployment;
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

  const deployment = new Deployment(
    'onepassword-connect',
    {
      metadata: { name: 'onepassword-connect', namespace },
      spec: buildOnePasswordConnectSpec(createCredentials(cluster, namespace, inputs)),
    },
    { provider: cluster },
  );

  const service = createService(cluster, namespace);

  return {
    deployment,
    serviceURL: all([service.metadata.name, service.metadata.namespace]).apply(
      ([name, serviceNamespace]) =>
        `http://${name}.${serviceNamespace}.svc.cluster.local:${onePasswordConnectServicePort}`,
    ),
  };
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
