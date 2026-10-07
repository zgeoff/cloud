import type { input } from '@pulumi/kubernetes/types';
import {
  onePasswordConnectAPIPort,
  onePasswordConnectLabels,
} from './build-onepassword-connect-spec.ts';

// The Service's port, which the host relay dials. It stays 8000, the proxy's old port:
// server-side apply keys Service ports by number, so a new number under the same name
// fails as a duplicate. Only the target moves to connect-api.
export const onePasswordConnectServicePort = 8000;

// The host relay (nixos/hosts/geoffcloud/configuration.nix) dials this address, so the
// Service keeps it; a cluster rebuild must keep it free. It is the Service's live value.
const serviceClusterIP = '10.43.82.198';

// Connect's Service: the pinned ClusterIP, its port 8000 to connect-api
export function buildOnePasswordConnectServiceSpec(): input.core.v1.ServiceSpec {
  return {
    clusterIP: serviceClusterIP,
    selector: onePasswordConnectLabels,
    ports: [
      {
        name: 'http',
        port: onePasswordConnectServicePort,
        targetPort: onePasswordConnectAPIPort,
      },
    ],
  };
}
