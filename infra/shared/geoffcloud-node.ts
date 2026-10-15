import { exposure, topology } from '@zgeoff/cloud-topology';
import { getExposurePort } from './get-exposure-port.ts';

// The host's own tailnet node (geoffcloud, tag:cloud). A long-lived node, so its address is stable.
// nixie's ingress binds its registry port, 443, on this address alone, and nixie.geoff.cloud points
// at it.
export const geoffcloudNode = {
  ip: topology.tailnet.nodes.geoffcloud.address,
  httpsPort: getExposurePort(exposure, 'nixie-ingress'),
};
