import { observabilityNamespace } from './observability-namespace.ts';

// Loki's in-cluster URL: the loki chart's Service in the observability namespace. Alloy pushes logs
// to it, and Grafana reads them from it.
export const lokiURL = `http://loki.${observabilityNamespace}.svc:3100`;
