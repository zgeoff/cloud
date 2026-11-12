import { expect, test } from 'bun:test';
import {
  buildBoxxyOwnerServiceSpec,
  buildBoxxyWorkerServiceSpec,
} from './build-boxxy-service-specs.ts';

test('it gives the owner listener a Service with no fixed address', () => {
  expect(buildBoxxyOwnerServiceSpec()).toStrictEqual({
    selector: { app: 'boxxy-server' },
    ports: [{ name: 'owner', port: 8090, targetPort: 'owner' }],
  });
});

test("it pins the worker listener's Service to the topology's address, with the worker port alone", () => {
  expect(buildBoxxyWorkerServiceSpec()).toStrictEqual({
    clusterIP: '10.43.0.80',
    selector: { app: 'boxxy-server' },
    ports: [{ name: 'worker', port: 8091, targetPort: 'worker' }],
  });
});
