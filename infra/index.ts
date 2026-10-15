// the program's entry point: it reads the inputs once and wires each group through its entry module
import { Provider } from '@pulumi/kubernetes';
import { Config } from '@pulumi/pulumi';
import { createCluster } from './cluster/index.ts';
import { createEdge } from './edge/index.ts';
import { createIngress } from './ingress/index.ts';
import { buildATCDaemonEndpoints, loadInputs } from './inputs/index.ts';
import { createObservability } from './observability/index.ts';
import { createTailnet } from './tailnet/index.ts';

// The one place the program reads its stack config and env (.env's op:// refs, through `op
// run`); every value is checked before any resource registers.
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

// k3s workloads (#6), with their inputs checked at the top of the program. Pulumi reaches the
// k3s API over the tailnet with the kubeconfig from op://cloud/k3s-kubeconfig.
const k3s =
  inputs.cluster === undefined
    ? undefined
    : {
        inputs: inputs.cluster,
        provider: new Provider('geoffcloud', { kubeconfig: inputs.cluster.kubeconfig }),
      };

const workloads =
  k3s === undefined
    ? undefined
    : createCluster(k3s.provider, {
        ...(k3s.inputs.atcGateway === undefined ? {} : { atcGateway: k3s.inputs.atcGateway }),
        onePasswordConnect: {
          credentials: k3s.inputs.onePasswordConnectCredentials,
        },
        ...(k3s.inputs.nixie === undefined ? {} : { nixie: k3s.inputs.nixie }),
        zoneID: edge.zoneID,
      });

const ingress = createIngress({
  accountID,
  zoneID: edge.zoneID,
  cluster: k3s?.provider,
  atcRoute: workloads?.atcGatewayRoute,
});

export const tunnelToken = ingress.tunnelToken;
export const tunnelConfigVersion = ingress.tunnelConfigVersion;
export const atcURL = ingress.atcURL;
export const previewWebhookURL = ingress.previewWebhookURL;
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
          alertWebhookURL: k3s.inputs.alertWebhookURL,
          atcDaemons: buildATCDaemonEndpoints(k3s.inputs.atcGateway?.config),
        },
});

export const grafanaURL = observability.grafanaURL;
export const grafanaAdminPassword = observability.grafanaAdminPassword;
export const healthCheckCron = observability.healthCheckCron;
