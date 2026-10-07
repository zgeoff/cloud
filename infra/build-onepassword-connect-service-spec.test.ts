import { expect, test } from 'bun:test';
import { buildOnePasswordConnectServiceSpec } from './build-onepassword-connect-service-spec.ts';

test("it keeps the ClusterIP the host relay dials and sends the Service's port 8000 to connect-api's 8080", () => {
  expect(buildOnePasswordConnectServiceSpec()).toStrictEqual({
    clusterIP: '10.43.82.198',
    selector: { app: 'onepassword-connect' },
    ports: [{ name: 'http', port: 8000, targetPort: 8080 }],
  });
});
