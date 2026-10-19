import type { input } from '@pulumi/kubernetes/types';
import { topology } from '@zgeoff/cloud-topology';
import {
  onePasswordConnectAPIPort,
  onePasswordConnectLabels,
} from './build-onepassword-connect-spec.ts';

export const onePasswordConnectServicePort = topology.onePasswordConnect.port;

// The host relay dials this address, so a cluster rebuild must keep it free.
const serviceClusterIP = topology.onePasswordConnect.clusterIP;

export function buildOnePasswordConnectServiceSpec(): input.core.v1.ServiceSpec {
  return {
    clusterIP: serviceClusterIP,
    selector: onePasswordConnectLabels,
    ports: [
      {
        name: 'http',

        // server-side apply keys Service ports by number, so a new number under the same name fails
        // as a duplicate
        port: onePasswordConnectServicePort,
        targetPort: onePasswordConnectAPIPort,
      },
    ],
  };
}
