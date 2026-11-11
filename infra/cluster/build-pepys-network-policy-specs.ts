import type { input } from '@pulumi/kubernetes/types';
import { podLabels } from '../shared/pod-labels.ts';
import { pepysWorkloads } from './pepys-workloads.ts';

type NetworkPolicySpec = input.networking.v1.NetworkPolicySpec;

// Each pepys pod admits only its callers. kube-router admits the node's own addresses before any
// policy, so a relay on the host still reaches a Service.
export function buildPepysNetworkPolicySpecs(): Readonly<Record<string, NetworkPolicySpec>> {
  const workloads = pepysWorkloads;

  return {
    // s2-lite keeps the log in Garage, and the backup reads every bucket
    [workloads.garage.name]: buildIngressPolicy(workloads.garage.labels, [
      { port: workloads.garage.s3Port, from: [toPeer(workloads.s2), toPeer(workloads.backup)] },
    ]),
    [workloads.s2.name]: buildIngressPolicy(workloads.s2.labels, [
      { port: workloads.s2.port, from: [toPeer(workloads.ingest), toPeer(workloads.host)] },
    ]),

    // the shared tunnel's cloudflared carries the public routes
    [workloads.ingest.name]: buildIngressPolicy(workloads.ingest.labels, [
      {
        port: workloads.ingest.port,
        from: [
          {
            namespaceSelector: { matchLabels: { 'kubernetes.io/metadata.name': 'ingress' } },
            podSelector: { matchLabels: podLabels.cloudflared },
          },
        ],
      },
    ]),

    // no caller in the cluster yet: the owner reaches the API through a port-forward
    [workloads.host.name]: buildIngressPolicy(workloads.host.labels, []),
    [workloads.backup.name]: buildIngressPolicy(workloads.backup.labels, []),
  };
}

type NetworkPolicyPeer = input.networking.v1.NetworkPolicyPeer;

interface Admission {
  readonly port: number;
  readonly from: NetworkPolicyPeer[];
}

function buildIngressPolicy(
  labels: Readonly<Record<string, string>>,
  admissions: readonly Admission[],
): NetworkPolicySpec {
  return {
    podSelector: { matchLabels: labels },
    policyTypes: ['Ingress'],
    ingress: admissions.map((admission) => ({
      from: admission.from,
      ports: [{ protocol: 'TCP', port: admission.port }],
    })),
  };
}

interface Labelled {
  readonly labels: Readonly<Record<string, string>>;
}

function toPeer(workload: Labelled): NetworkPolicyPeer {
  return { podSelector: { matchLabels: workload.labels } };
}
