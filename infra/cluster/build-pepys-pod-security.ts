import type { input } from '@pulumi/kubernetes/types';
import { pepysUserID } from '../shared/pepys-workloads.ts';

// every pepys pod runs as the nonroot user, with no service account token and no service links
export function buildPepysPodSecurity() {
  return {
    securityContext: {
      fsGroup: pepysUserID,
      runAsNonRoot: true,
      runAsUser: pepysUserID,
      runAsGroup: pepysUserID,
      seccompProfile: { type: 'RuntimeDefault' },
    },
    automountServiceAccountToken: false,
    enableServiceLinks: false,
  } satisfies Partial<input.core.v1.PodSpec>;
}
