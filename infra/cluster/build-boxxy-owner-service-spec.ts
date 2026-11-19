import type { input } from '@pulumi/kubernetes/types';
import { topology } from '@zgeoff/cloud-topology';
import { boxxyLabels } from './build-boxxy-spec.ts';
import { boxxyOwnerPort, boxxyWorkerPort } from './render-boxxy-config.ts';

// The owner listener's Service: the tailnet route's target, with no fixed address.
export function buildBoxxyOwnerServiceSpec(): input.core.v1.ServiceSpec {
  return {
    selector: boxxyLabels,
    ports: [{ name: 'owner', port: boxxyOwnerPort, targetPort: 'owner' }],
  };
}

// The worker listener's Service, alone on its pinned ClusterIP: the host's relay dials this
// address for the broker, so a cluster rebuild must keep it free. The owner listener takes no
// token, so it never sits behind this address.
export function buildBoxxyWorkerServiceSpec(): input.core.v1.ServiceSpec {
  return {
    clusterIP: topology.boxxy.workerClusterIP,
    selector: boxxyLabels,
    ports: [{ name: 'worker', port: boxxyWorkerPort, targetPort: 'worker' }],
  };
}
