import { exposure, topology } from '@zgeoff/cloud-topology';
import { getExposurePort } from './get-exposure-port.ts';

export const geoffcloudNode = {
  // a long-lived node, so its address is stable
  ip: topology.tailnet.nodes.geoffcloud.address,
  httpsPort: getExposurePort(exposure, 'nixie-ingress'),
};
