import { nixieAPIPort } from './build-nixie-spec.ts';

export const nixieReadinessURL = `http://nixie.nixie.svc.cluster.local:${String(nixieAPIPort)}/health/ready`;
