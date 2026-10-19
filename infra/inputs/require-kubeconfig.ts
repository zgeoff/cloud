import { findVariable } from './find-variable.ts';
import type { Environment } from './types.ts';

const clusterModes = ['managed', 'none'] as const;

export function requireKubeconfig(mode: string | undefined, env: Environment): string | undefined {
  if (!isClusterMode(mode)) {
    throw new Error(
      `stack config "cluster" is ${mode === undefined ? 'unset' : `"${mode}"`}; set it to ${clusterModes.join(' or ')}`,
    );
  }

  if (mode === 'none') {
    return undefined;
  }

  const kubeconfig = findVariable(env, 'K3S_KUBECONFIG');

  // a missing K3S_KUBECONFIG must not read as "no cluster" and plan to delete every cluster
  // resource
  if (kubeconfig === undefined) {
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
