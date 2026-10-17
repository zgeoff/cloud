import { nixieAPIPort } from './build-nixie-spec.ts';

// nixie's readiness report from inside the cluster, through the Service and the namespace that
// nixie.ts both names nixie. Observability probes it for the advisory parts in its body.
export const nixieReadinessURL = `http://nixie.nixie.svc.cluster.local:${String(nixieAPIPort)}/health/ready`;
