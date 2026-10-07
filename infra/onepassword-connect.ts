import type { Provider } from '@pulumi/kubernetes';
import { Deployment } from '@pulumi/kubernetes/apps/v1';
import { ConfigMap, Namespace, Secret, Service } from '@pulumi/kubernetes/core/v1';
import type { input } from '@pulumi/kubernetes/types';
import type { Output } from '@pulumi/pulumi';
import { all, secret } from '@pulumi/pulumi';
import {
  buildOnePasswordConnectProxyConfig,
  onePasswordConnectProxyPort,
} from './build-onepassword-connect-proxy-config.ts';

// 1Password Connect, for imps (GEO-120): imp's credential broker swaps a placeholder
// bearer for the real Connect token on requests to op-connect.imp.internal and forwards
// them to a relay on the host, which dials this Service's ClusterIP. Connect has no public
// route. The pod follows 1Password's Helm chart (charts/connect in
// 1Password/connect-helm-charts), plus an nginx proxy that is the only port on the
// Service: it passes only GET and HEAD. Pods in the cluster can still reach Connect's own
// ports directly; they need the bearer token either way.

// The host relay (nixos/hosts/geoffcloud/configuration.nix) dials this address, so the
// Service keeps it; a cluster rebuild must keep it free. It is the Service's live value.
const serviceClusterIP = '10.43.82.198';

// Connect's release; bump deliberately
const connectVersion = '1.8.3';
const connectAPIImage = `1password/connect-api:${connectVersion}`;
const connectSyncImage = `1password/connect-sync:${connectVersion}`;

// nginx's release; bump deliberately
const proxyImage = 'nginxinc/nginx-unprivileged:1.30.5-alpine';
const credentialsKey = '1password-credentials.json';
const credentialsPath = `/home/opuser/.op/${credentialsKey}`;
const dataPath = '/home/opuser/.op/data';
const labels = { app: 'onepassword-connect' };

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
  const objects = createConfigObjects(cluster, namespace, inputs);

  const deployment = new Deployment(
    'onepassword-connect',
    {
      metadata: { name: 'onepassword-connect', namespace },
      spec: buildSpec(objects.credentials, objects.proxyConfig),
    },
    { provider: cluster },
  );

  const service = createService(cluster, namespace);

  return {
    deployment,
    serviceURL: all([service.metadata.name, service.metadata.namespace]).apply(
      ([name, serviceNamespace]) =>
        `http://${name}.${serviceNamespace}.svc.cluster.local:${onePasswordConnectProxyPort}`,
    ),
  };
}

function createService(cluster: Provider, namespace: Output<string>): Service {
  return new Service(
    'onepassword-connect',
    {
      metadata: { name: 'onepassword-connect', namespace },
      spec: {
        clusterIP: serviceClusterIP,
        selector: labels,
        ports: [
          {
            name: 'http',
            port: onePasswordConnectProxyPort,
            targetPort: onePasswordConnectProxyPort,
          },
        ],
      },
    },
    {
      provider: cluster,

      // clusterIP is immutable, so pinning it in a change to the live Service would replace
      // the Service. The state already holds the live value; a new Service takes the pin.
      ignoreChanges: ['spec.clusterIP'],
    },
  );
}

// no fixed names on the Secret and the ConfigMap: Pulumi names them and replaces them on a
// change, so the Deployment rolls and Connect and the proxy pick the change up
function createConfigObjects(
  cluster: Provider,
  namespace: Output<string>,
  inputs: OnePasswordConnectInputs,
): { readonly credentials: Output<string>; readonly proxyConfig: Output<string> } {
  const credentials = new Secret(
    'onepassword-connect-credentials',
    { metadata: { namespace }, stringData: { [credentialsKey]: secret(inputs.credentials) } },
    { provider: cluster },
  );

  const proxyConfig = new ConfigMap(
    'onepassword-connect-proxy',
    {
      metadata: { namespace },
      data: {
        'default.conf': buildOnePasswordConnectProxyConfig(),
      },
    },
    { provider: cluster },
  );

  return { credentials: credentials.metadata.name, proxyConfig: proxyConfig.metadata.name };
}

const lockedDown: input.core.v1.SecurityContext = {
  allowPrivilegeEscalation: false,
  readOnlyRootFilesystem: true,
  capabilities: { drop: ['ALL'] },
};

const podSecurityContext: input.core.v1.PodSecurityContext = {
  fsGroup: 999,
  runAsUser: 999,
  runAsGroup: 999,
  runAsNonRoot: true,
  seccompProfile: { type: 'RuntimeDefault' },
};

function buildSpec(
  credentialsSecret: Output<string>,
  proxyConfigMap: Output<string>,
): input.apps.v1.DeploymentSpec {
  return {
    replicas: 1,
    selector: { matchLabels: labels },
    template: {
      metadata: { labels },
      spec: {
        securityContext: podSecurityContext,
        volumes: [
          { name: 'shared-data', emptyDir: {} },
          { name: 'credentials', secret: { secretName: credentialsSecret } },
          { name: 'proxy-config', configMap: { name: proxyConfigMap } },
          { name: 'proxy-tmp', emptyDir: {} },
        ],
        containers: [
          buildConnectContainer({
            name: 'connect-api',
            image: connectAPIImage,
            httpPort: 8080,
            busPort: 11_220,
            peerPort: 11_221,
            memory: '128Mi',
          }),
          buildConnectContainer({
            name: 'connect-sync',
            image: connectSyncImage,
            httpPort: 8081,
            busPort: 11_221,
            peerPort: 11_220,
            memory: '128Mi',
          }),
          buildProxyContainer(),
        ],
      },
    },
  };
}

function buildProxyContainer(): input.core.v1.Container {
  return {
    name: 'proxy',
    image: proxyImage,
    ports: [{ name: 'http', containerPort: onePasswordConnectProxyPort }],

    // a TCP probe: an HTTP one would need Connect's own health path through the proxy
    readinessProbe: { tcpSocket: { port: onePasswordConnectProxyPort } },
    volumeMounts: [
      { name: 'proxy-config', mountPath: '/etc/nginx/conf.d', readOnly: true },

      // nginx-unprivileged writes its pid and temp files under /tmp
      { name: 'proxy-tmp', mountPath: '/tmp' },
    ],
    securityContext: lockedDown,
    resources: { requests: { cpu: '5m', memory: '16Mi' }, limits: { memory: '32Mi' } },
  };
}

interface ConnectContainer {
  readonly name: string;
  readonly image: string;
  readonly httpPort: number;
  readonly busPort: number;
  readonly peerPort: number;
  readonly memory: string;
}

// connect-api and connect-sync differ only in ports and image; they share a data volume
// and talk over the pod's loopback
function buildConnectContainer(spec: ConnectContainer): input.core.v1.Container {
  return {
    name: spec.name,
    image: spec.image,
    env: [
      { name: 'OP_HTTP_PORT', value: String(spec.httpPort) },
      { name: 'OP_SESSION', value: credentialsPath },
      { name: 'OP_BUS_PORT', value: String(spec.busPort) },
      { name: 'OP_BUS_PEERS', value: `localhost:${spec.peerPort}` },
      { name: 'OP_LOG_LEVEL', value: 'info' },
    ],
    readinessProbe: { httpGet: { path: '/health', port: spec.httpPort } },
    livenessProbe: {
      httpGet: { path: '/heartbeat', port: spec.httpPort },
      periodSeconds: 30,
      failureThreshold: 3,
      initialDelaySeconds: 15,
    },
    volumeMounts: [
      { name: 'shared-data', mountPath: dataPath },
      { name: 'credentials', mountPath: credentialsPath, subPath: credentialsKey, readOnly: true },
    ],
    securityContext: lockedDown,
    resources: { requests: { cpu: '10m', memory: '32Mi' }, limits: { memory: spec.memory } },
  };
}
