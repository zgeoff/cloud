import type { input } from '@pulumi/kubernetes/types';
import { topology } from '@zgeoff/cloud-topology';
import { pepysWorkloads } from './pepys-workloads.ts';

type NetworkPolicySpec = input.networking.v1.NetworkPolicySpec;

type NetworkPolicyEgressRule = input.networking.v1.NetworkPolicyEgressRule;

const dns: NetworkPolicyEgressRule = {
  to: [
    {
      namespaceSelector: { matchLabels: { 'kubernetes.io/metadata.name': 'kube-system' } },
      podSelector: { matchLabels: { 'k8s-app': 'kube-dns' } },
    },
  ],
  ports: [
    { protocol: 'UDP', port: 53 },
    { protocol: 'TCP', port: 53 },
  ],
};

const internetOn443: NetworkPolicyEgressRule = {
  to: [
    {
      ipBlock: {
        cidr: '0.0.0.0/0',
        except: [
          topology.k3s.podCIDR,
          topology.k3s.serviceCIDR,
          topology.tailnet.cidr,
          topology.podman.subnet,
        ],
      },
    },
  ],
  ports: [{ protocol: 'TCP', port: 443 }],
};

// The pepys namespace allows no egress, so each rule here is all that its pod may dial. A policy
// sees the address after kube-proxy's DNAT, so DNS selects the CoreDNS pods, not the Service.
// No pepys pod calls the Kubernetes API: none mounts a service account token.
export function buildPepysEgressPolicySpecs(): Readonly<Record<string, NetworkPolicySpec>> {
  const workloads = pepysWorkloads;
  const toGarage = toPeer(workloads.garage.labels, workloads.garage.s3Port);
  const toS2 = toPeer(workloads.s2.labels, workloads.s2.port);

  return {
    // Garage runs one node, and its RPC address is loopback
    [`${workloads.garage.name}-egress`]: buildEgressPolicy(workloads.garage.labels, []),
    [`${workloads.s2.name}-egress`]: buildEgressPolicy(workloads.s2.labels, [dns, toGarage]),

    // ingest calls the GitHub API; it keeps no blob, so it never calls Garage
    [`${workloads.ingest.name}-egress`]: buildEgressPolicy(workloads.ingest.labels, [
      dns,
      toS2,
      internetOn443,
    ]),

    // the API reads the store's files and dials nothing
    [`${workloads.host.name}-egress`]: buildEgressPolicy(workloads.host.labels, [dns, toS2]),

    // R2 is the backup's target
    [`${workloads.backup.name}-egress`]: buildEgressPolicy(workloads.backup.labels, [
      dns,
      toGarage,
      internetOn443,
    ]),
  };
}

function toPeer(labels: Readonly<Record<string, string>>, port: number): NetworkPolicyEgressRule {
  return {
    to: [{ podSelector: { matchLabels: labels } }],
    ports: [{ protocol: 'TCP', port }],
  };
}

function buildEgressPolicy(
  labels: Readonly<Record<string, string>>,
  egress: NetworkPolicyEgressRule[],
): NetworkPolicySpec {
  return { podSelector: { matchLabels: labels }, policyTypes: ['Egress'], egress };
}
