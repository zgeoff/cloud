import type { input } from '@pulumi/kubernetes/types';

export function buildPepysContainerSecurity() {
  return {
    allowPrivilegeEscalation: false,
    readOnlyRootFilesystem: true,
    capabilities: { drop: ['ALL'] },
  } satisfies input.core.v1.SecurityContext;
}
