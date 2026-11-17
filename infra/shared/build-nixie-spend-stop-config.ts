import type { Exposure, Topology } from '@zgeoff/cloud-topology';
import { getExposurePort } from './get-exposure-port.ts';

export interface NixieSpendStopConfig {
  readonly control: string;
  readonly token: string;
  readonly modelURL: string;
}

// nixie's spendStop section, which points nixie at the model gateway on the host
// (nixos/modules/model-gateway.nix)
export function buildNixieSpendStopConfig(
  topology: Readonly<Topology>,
  exposure: Readonly<Exposure>,
): NixieSpendStopConfig {
  return {
    // the pod's loopback is its own, so nixie dials the control relay on the host's tailnet address,
    // which nixie's network policy allows
    control: `http://${topology.tailnet.nodes.geoffcloud.address}:${getExposurePort(exposure, 'model-gateway-control-relay')}`,

    // the settings entry of the sops file that holds the gateway's control token
    token: 'deployment:gateway-control',

    // the model listener on imp-host's bridge, where imp-host's broker sends each model request: the
    // upstream of each nixie-model-* secret in impd
    modelURL: `http://${topology.podman.bridgeAddress}:${getExposurePort(exposure, 'model-gateway-model')}`,
  };
}
