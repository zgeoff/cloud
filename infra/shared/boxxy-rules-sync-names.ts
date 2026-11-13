import { podLabels } from './pod-labels.ts';

export const boxxyRulesSyncNames = {
  namespace: 'boxxy' as const,
  labels: podLabels.boxxyServer,
  container: 'rules-sync',
  httpPort: 'rules-sync',
  httpPortNumber: 2020,
};
