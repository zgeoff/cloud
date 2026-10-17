import { expect, test } from 'bun:test';
import { nixieReadinessURL } from './nixie-readiness-url.ts';

test("it points at /health/ready on nixie's API port through its Service", () => {
  expect(nixieReadinessURL).toBe('http://nixie.nixie.svc.cluster.local:8080/health/ready');
});
