// How the stack treats the k3s cluster: `managed` applies its workloads, `none` leaves the
// cluster out (a host that has no k3s yet). Set it with `pulumi config set cluster <mode>`.
const clusterModes = ['managed', 'none'] as const;

// The kubeconfig for the cluster, or undefined when the stack leaves the cluster out.
// An unset mode, or `managed` without a kubeconfig, throws:
// otherwise a missing K3S_KUBECONFIG would read as "no cluster" and plan to delete every
// cluster resource.
export function requireKubeconfig(
  mode: string | undefined,
  kubeconfig: string | undefined,
): string | undefined {
  if (!isClusterMode(mode)) {
    throw new Error(
      `stack config "cluster" is ${mode === undefined ? 'unset' : `"${mode}"`}; set it to ${clusterModes.join(' or ')}`,
    );
  }

  if (mode === 'none') {
    return undefined;
  }

  if (kubeconfig === undefined || kubeconfig.trim() === '') {
    throw new Error(
      'cluster is managed, but K3S_KUBECONFIG is empty; run through `op run --env-file=../.env`',
    );
  }

  return kubeconfig;
}

type ClusterMode = (typeof clusterModes)[number];

function isClusterMode(value: string | undefined): value is ClusterMode {
  return clusterModes.some((mode) => mode === value);
}
