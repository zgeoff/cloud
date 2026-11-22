import { expect, test } from 'bun:test';
import { buildNixieRoutesNamespaces } from './build-nixie-routes-namespaces.ts';

test("it leaves pepys's namespace out of nixie's Traefik while pepys has no tailnet route", () => {
  expect(buildNixieRoutesNamespaces(false)).toStrictEqual(['nixie']);
});

test("it adds pepys's namespace to nixie's Traefik while pepys has a tailnet route", () => {
  expect(buildNixieRoutesNamespaces(true)).toStrictEqual(['nixie', 'pepys']);
});
