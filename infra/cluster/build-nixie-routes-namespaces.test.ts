import { expect, test } from 'bun:test';
import { buildNixieRoutesNamespaces } from './build-nixie-routes-namespaces.ts';

test("it leaves pepys's tailnet route out of nixie's Traefik while the tailnet hostname is unset", () => {
  expect(buildNixieRoutesNamespaces(undefined)).toStrictEqual(['nixie']);
});

test("it adds pepys's namespace to nixie's Traefik while the tailnet hostname is set", () => {
  expect(buildNixieRoutesNamespaces('pepys-api.geoff.cloud')).toStrictEqual(['nixie', 'pepys']);
});
