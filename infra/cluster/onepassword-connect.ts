import type { Provider } from '@pulumi/kubernetes';
import { Deployment } from '@pulumi/kubernetes/apps/v1';
import type { DeploymentArgs } from '@pulumi/kubernetes/apps/v1';
import { Secret, Service } from '@pulumi/kubernetes/core/v1';
import { NetworkPolicy } from '@pulumi/kubernetes/networking/v1';
import type { Output } from '@pulumi/pulumi';
import { secret } from '@pulumi/pulumi';
import { createNamespace } from '../shared/create-namespace.ts';
import { buildOnePasswordConnectNetworkPolicySpec } from './build-onepassword-connect-network-policy-spec.ts';
import {
  buildOnePasswordConnectServiceSpec,
  onePasswordConnectServicePort,
} from './build-onepassword-connect-service-spec.ts';
import {
  buildOnePasswordConnectSpec,
  onePasswordConnectCredentialsKey,
} from './build-onepassword-connect-spec.ts';
import { buildServiceURL } from './build-service-url.ts';

export interface OnePasswordConnectInputs {
  readonly credentials: Output<string>;
}

interface OnePasswordConnectOutputs {
  readonly serviceURL: Output<string>;
}

export function createOnePasswordConnect(
  cluster: Provider,
  inputs: OnePasswordConnectInputs,
): OnePasswordConnectOutputs {
  const ns = createNamespace('onepassword', cluster);
  const namespace = ns.metadata.name;

  createDeployment(
    cluster,
    namespace,
    buildOnePasswordConnectSpec(createCredentials(cluster, namespace, inputs)),
  );

  const service = createService(cluster, namespace);

  createNetworkPolicy(cluster, namespace);

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

function createNetworkPolicy(cluster: Provider, namespace: Output<string>): NetworkPolicy {
  return new NetworkPolicy(
    'onepassword-connect',
    {
      metadata: { name: 'onepassword-connect', namespace },
      spec: buildOnePasswordConnectNetworkPolicySpec(),
    },
    { provider: cluster },
  );
}

function createCredentials(
  cluster: Provider,
  namespace: Output<string>,
  inputs: OnePasswordConnectInputs,
): Output<string> {
  const credentials = new Secret(
    'onepassword-connect-credentials',
    {
      // no fixed name: Pulumi replaces the Secret on a change, so the Deployment rolls and Connect
      // picks the change up
      metadata: { namespace },
      stringData: { [onePasswordConnectCredentialsKey]: secret(inputs.credentials) },
    },
    { provider: cluster },
  );

  return credentials.metadata.name;
}
