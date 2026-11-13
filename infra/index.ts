import { Config, secret } from '@pulumi/pulumi';
import { createCluster, createClusterProvider } from './cluster/index.ts';
import { createEdge } from './edge/index.ts';
import { createIngress, createSidecarTunnel } from './ingress/index.ts';
import { buildATCDaemonEndpoints, loadInputs } from './inputs/index.ts';
import { createObservability } from './observability/index.ts';
import { createTailnet } from './tailnet/index.ts';

// the env holds .env's op:// refs, resolved through `op run`
const inputs = loadInputs(new Config(), process.env);
const accountID = inputs.accountID;
const edge = createEdge({ accountID, hostOnTailnet: inputs.hostOnTailnet });

export const domain = edge.domain;
export const zoneID = edge.zoneID;
export const backupsBucket = edge.backupsBucket;
export const edgeFirewallID = edge.edgeFirewallID;
export const geoffcloudIPv4 = edge.geoffcloudIPv4;
export const alwaysHTTPSValue = edge.alwaysHTTPSValue;
const tailnet = createTailnet();

export const tailnetPolicyID = tailnet.tailnetPolicyID;
export const hostAuthKey = tailnet.hostAuthKey;
export const impKeySyncID = tailnet.impKeySyncID;
export const impHostAuthKey = tailnet.impHostAuthKey;

// Pulumi reaches the k3s API over the tailnet with the kubeconfig from op://cloud/k3s-kubeconfig
const k3s =
  inputs.cluster === undefined
    ? undefined
    : {
        inputs: inputs.cluster,
        provider: createClusterProvider('geoffcloud', { kubeconfig: inputs.cluster.kubeconfig }),
      };

// the atc tunnel's connector runs in the gateway's pod, and the boxxy door tunnel's in the boxxy
// server's, so each tunnel comes before the cluster
const atcTunnel =
  k3s?.inputs.atcGateway === undefined
    ? undefined
    : createSidecarTunnel(accountID, { resourceName: 'atc', tunnelName: 'geoff-cloud-atc' });

const boxxyDoor = k3s?.inputs.boxxy?.config.publicDoor;

const boxxyTunnel =
  boxxyDoor === undefined
    ? undefined
    : createSidecarTunnel(accountID, { resourceName: 'boxxy', tunnelName: 'geoff-cloud-boxxy' });

const workloads =
  k3s === undefined
    ? undefined
    : createCluster(k3s.provider, {
        ...(k3s.inputs.atcGateway === undefined || atcTunnel === undefined
          ? {}
          : {
              atcGateway: { inputs: k3s.inputs.atcGateway, tunnelToken: atcTunnel.tunnelToken },
            }),
        onePasswordConnect: {
          credentials: k3s.inputs.onePasswordConnectCredentials,
        },
        ...(k3s.inputs.nixie === undefined ? {} : { nixie: k3s.inputs.nixie }),
        ...(k3s.inputs.files === undefined ? {} : { files: k3s.inputs.files }),
        ...(k3s.inputs.pepys === undefined ? {} : { pepys: k3s.inputs.pepys }),
        ...(k3s.inputs.boxxy === undefined ? {} : { boxxy: k3s.inputs.boxxy }),
        ...(boxxyTunnel === undefined ? {} : { boxxyDoorTunnelToken: boxxyTunnel.tunnelToken }),
        zoneID: edge.zoneID,
        kubeconfig: secret(k3s.inputs.kubeconfig),
      });

const ingress = createIngress({
  accountID,
  zoneID: edge.zoneID,
  cluster: k3s?.provider,
  atcRoute: workloads?.atcGatewayRoute,
  ownerEmail: k3s?.inputs.atcGateway?.secrets.ownerEmail,
  atcTunnel,
  boxxyDoorHostname: boxxyDoor === undefined ? undefined : new URL(boxxyDoor.publicURL).hostname,
  boxxyTunnel,
  filesRoute: workloads?.filesRoute,
  pepysRoute: workloads?.pepysRoute,
  pepysAPIRoute: workloads?.pepysAPIRoute,
});

export const tunnelToken = ingress.tunnelToken;
export const tunnelConfigVersion = ingress.tunnelConfigVersion;
export const atcTunnelConfigVersion = ingress.atcTunnelConfigVersion;
export const atcURL = ingress.atcURL;
export const boxxyDoorConfigVersion = ingress.boxxyDoorConfigVersion;
export const boxxyDoorURL = ingress.boxxyDoorURL;
export const previewWebhookURL = ingress.previewWebhookURL;
export const filesURL = ingress.filesURL;
export const pepysWebhookURL = ingress.pepysWebhookURL;
export const pepysAPIURL = ingress.pepysAPIURL;
export const onePasswordConnectServiceURL = workloads?.onePasswordConnectServiceURL;
export const atcGatewayServiceURL = workloads?.atcGatewayServiceURL;
export const nixieURL = workloads?.nixieURL;

const observability = await createObservability({
  accountID,
  alertURL: inputs.alertURL,
  atcHealthURL: workloads?.atcGatewayRoute?.healthURL,
  cluster:
    k3s === undefined
      ? undefined
      : {
          provider: k3s.provider,
          alertWebhook: k3s.inputs.alertWebhook,
          atcDaemons: buildATCDaemonEndpoints(k3s.inputs.atcGateway?.config),
          nixieReadinessURL: workloads?.nixieReadinessURL,
          boxxyRulesSync: workloads?.boxxyServiceURL !== undefined,
        },
});

export const grafanaURL = observability.grafanaURL;
export const grafanaAdminPassword = observability.grafanaAdminPassword;
export const healthCheckCron = observability.healthCheckCron;
