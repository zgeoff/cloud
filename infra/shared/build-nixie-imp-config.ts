import type { Topology } from '@zgeoff/cloud-topology';

export interface NixieImpConfig {
  readonly url: string;
  readonly host_addresses: readonly string[];
  readonly egress_deny: readonly string[];
}

export function buildNixieImpConfig(topology: Readonly<Topology>): NixieImpConfig {
  const nodePods = splitCIDR(topology.k3s.nodePodCIDR);

  return {
    // impd's API on its own tailnet node; the pod reaches it through the host's node (tag:cloud)
    url: `https://${topology.imp.domain}`,

    // impd's own IMP_HOST_ADDRESSES, which imp's module reads from the host's interfaces: public
    // egress needs them, and nixie's web fetch tool refuses them
    host_addresses: [
      `${topology.vm.publicIPv4}/${topology.vm.publicIPv4PrefixLength}`,
      `${topology.vm.publicIPv6}/${topology.vm.publicIPv6PrefixLength}`,
      `${topology.docker.bridgeAddress}/${splitCIDR(topology.docker.subnet).prefixLength}`,
      `${topology.tailnet.nodes.geoffcloud.address}/32`,
      `${topology.tailnet.nodes.geoffcloud.addressIPv6}/128`,

      // flannel.1 holds the node's pod subnet's network address, and cni0 its first address
      `${nodePods.address}/32`,
      `${toIPv4(toIPv4Number(nodePods.address) + 1)}/${nodePods.prefixLength}`,
    ],

    // k3s's pod and service ranges, which imp's module drops from imp-host's bridge as well
    egress_deny: [topology.k3s.podCIDR, topology.k3s.serviceCIDR],
  };
}

function splitCIDR(cidr: string): { readonly address: string; readonly prefixLength: number } {
  const [address = '', prefixLength = ''] = cidr.split('/');

  return { address, prefixLength: Number(prefixLength) };
}

function toIPv4(value: number): string {
  return [24, 16, 8, 0].map((shift) => Math.floor(value / 2 ** shift) % 256).join('.');
}

function toIPv4Number(address: string): number {
  return address.split('.').reduce((value, octet) => value * 256 + Number(octet), 0);
}
