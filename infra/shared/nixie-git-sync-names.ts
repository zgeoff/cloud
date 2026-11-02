import { podLabels } from './pod-labels.ts';

export const nixieGitSyncNames = {
  namespace: 'nixie' as const,
  labels: podLabels.nixie,
  container: 'git-sync',
  httpPort: 'git-sync',
  httpPortNumber: 8081,
};
