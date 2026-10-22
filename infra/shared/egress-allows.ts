import { exposure, topology } from '@zgeoff/cloud-topology';
import type { ClusterNamespace } from './cluster-namespaces.ts';
import { getExposurePort } from './get-exposure-port.ts';
import { podLabels } from './pod-labels.ts';

interface EgressDestination {
  readonly address: string;
  readonly port: number;
}

export interface EgressAllow {
  readonly name: string;
  readonly namespace: ClusterNamespace;
  readonly podLabels: Readonly<Record<string, string>>;
  readonly destinations: readonly EgressDestination[];
}

const hostDaemon = {
  address: topology.tailnet.nodes.geoffcloud.address,
  port: topology.atc.daemonPort,
};

// impd's HTTPS API, on imp's own node
const impd = { address: topology.tailnet.nodes.imp.address, port: 443 };

const homePCDaemon = {
  address: topology.tailnet.nodes.homePC.address,
  port: topology.atc.daemonPort,
};

// every other pod in a namespace with egress deny is refused the tailnet range and Docker's subnet
export const egressAllows = {
  atcGateway: {
    name: 'atc-gateway-egress',
    namespace: 'atc',
    podLabels: podLabels.atcGateway,
    destinations: [hostDaemon, homePCDaemon],
  },
  atcDaemonProbe: {
    name: 'atc-daemon-probe-egress',
    namespace: 'observability',
    podLabels: podLabels.atcDaemonProbe,
    destinations: [hostDaemon, homePCDaemon],
  },
  impHealthProbe: {
    name: 'imp-health-probe-egress',
    namespace: 'observability',
    podLabels: podLabels.impHealthProbe,
    destinations: [impd],
  },
  nixie: {
    name: 'nixie-egress',
    namespace: 'nixie',
    podLabels: podLabels.nixie,
    destinations: [impd],
  },
  cloudflared: {
    name: 'cloudflared-egress',
    namespace: 'ingress',
    podLabels: podLabels.cloudflared,
    destinations: [
      {
        address: topology.tailnet.nodes.geoffcloud.address,
        port: getExposurePort(exposure, 'preview-webhook'),
      },
    ],
  },
} as const satisfies Record<string, EgressAllow>;
