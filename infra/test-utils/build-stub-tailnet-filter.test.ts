import { expect, test } from 'bun:test';
import { buildStubTailnetFilter } from './build-stub-tailnet-filter.ts';

test.each([
  ['tcp', 22],
  ['tcp', 65_535],
  ['udp', 53],
  ['icmp', 0],
  ['ipv6-icmp', 0],
] as const)('it allows %s on port %d under ip *, as wgengine/filter does', (proto, port) => {
  const filter = buildStubTailnetFilter({
    hosts: {},
    grants: [{ src: ['*'], dst: ['*'], ip: ['*'] }],
  });

  expect(
    filter.canConnect(
      { ip: '100.64.0.1', roles: ['member'], tags: [] },
      { ip: '100.64.0.2', roles: ['member'], tags: [] },
      { proto, port },
    ),
  ).toBe(true);
});

test.each([
  [999, false],
  [1000, true],
  [2000, true],
  [2001, false],
])('it treats port %d against tcp:1000-2000 as allowed: %p', (port, allowed) => {
  const filter = buildStubTailnetFilter({
    hosts: {},
    grants: [{ src: ['*'], dst: ['*'], ip: ['tcp:1000-2000'] }],
  });

  expect(
    filter.canConnect(
      { ip: '100.64.0.1', roles: ['member'], tags: [] },
      { ip: '100.64.0.2', roles: ['member'], tags: [] },
      { proto: 'tcp', port },
    ),
  ).toBe(allowed);
});

test('it matches a single port entry on that port alone', () => {
  const filter = buildStubTailnetFilter({
    hosts: {},
    grants: [{ src: ['*'], dst: ['*'], ip: ['tcp:443'] }],
  });

  expect(
    filter.canConnect(
      { ip: '100.64.0.1', roles: ['member'], tags: [] },
      { ip: '100.64.0.2', roles: ['member'], tags: [] },
      { proto: 'tcp', port: 444 },
    ),
  ).toBe(false);
});

test('it matches ICMPv6 by its IANA number, 58', () => {
  const filter = buildStubTailnetFilter({
    hosts: {},
    grants: [{ src: ['*'], dst: ['*'], ip: ['58:*'] }],
  });

  expect(
    filter.canConnect(
      { ip: '100.64.0.1', roles: ['member'], tags: [] },
      { ip: '100.64.0.2', roles: ['member'], tags: [] },
      { proto: 'ipv6-icmp', port: 0 },
    ),
  ).toBe(true);
});

test('it refuses a protocol that the ip entry does not name', () => {
  const filter = buildStubTailnetFilter({
    hosts: {},
    grants: [{ src: ['*'], dst: ['*'], ip: ['tcp:*'] }],
  });

  expect(
    filter.canConnect(
      { ip: '100.64.0.1', roles: ['member'], tags: [] },
      { ip: '100.64.0.2', roles: ['member'], tags: [] },
      { proto: 'udp', port: 53 },
    ),
  ).toBe(false);
});

test('it refuses ICMP that no grant names, though the tailnet allows it between connected nodes', () => {
  const filter = buildStubTailnetFilter({
    hosts: {},
    grants: [{ src: ['*'], dst: ['*'], ip: ['tcp:443'] }],
  });

  expect(
    filter.canConnect(
      { ip: '100.64.0.1', roles: ['member'], tags: [] },
      { ip: '100.64.0.2', roles: ['member'], tags: [] },
      { proto: 'icmp', port: 0 },
    ),
  ).toBe(false);
});

test('it never selects a tagged node with autogroup:member', () => {
  const filter = buildStubTailnetFilter({
    hosts: {},
    grants: [{ src: ['autogroup:member'], dst: ['*'], ip: ['*'] }],
  });

  expect(
    filter.canConnect(
      { ip: '100.64.0.1', roles: [], tags: ['tag:cloud'] },
      { ip: '100.64.0.2', roles: ['member'], tags: [] },
      { proto: 'tcp', port: 22 },
    ),
  ).toBe(false);
});

test('it selects a device for autogroup:admin when its owner is an admin', () => {
  const filter = buildStubTailnetFilter({
    hosts: {},
    grants: [{ src: ['autogroup:admin'], dst: ['*'], ip: ['*'] }],
  });

  expect(
    filter.canConnect(
      { ip: '100.64.0.1', roles: ['admin', 'member'], tags: [] },
      { ip: '100.64.0.2', roles: ['member'], tags: [] },
      { proto: 'tcp', port: 22 },
    ),
  ).toBe(true);
});

test('it refuses autogroup:admin to a device whose owner is a member only', () => {
  const filter = buildStubTailnetFilter({
    hosts: {},
    grants: [{ src: ['autogroup:admin'], dst: ['*'], ip: ['*'] }],
  });

  expect(
    filter.canConnect(
      { ip: '100.64.0.1', roles: ['member'], tags: [] },
      { ip: '100.64.0.2', roles: ['member'], tags: [] },
      { proto: 'tcp', port: 22 },
    ),
  ).toBe(false);
});

test('it selects a node by tag', () => {
  const filter = buildStubTailnetFilter({
    hosts: {},
    grants: [{ src: ['tag:deploy'], dst: ['*'], ip: ['*'] }],
  });

  expect(
    filter.canConnect(
      { ip: '100.64.0.1', roles: [], tags: ['tag:deploy'] },
      { ip: '100.64.0.2', roles: ['member'], tags: [] },
      { proto: 'tcp', port: 22 },
    ),
  ).toBe(true);
});

test('it selects a node by host alias through its IPv4 address', () => {
  const filter = buildStubTailnetFilter({
    hosts: { server: '100.64.0.2' },
    grants: [{ src: ['*'], dst: ['server'], ip: ['*'] }],
  });

  expect(
    filter.canConnect(
      { ip: '100.64.0.1', roles: ['member'], tags: [] },
      { ip: '100.64.0.2', roles: [], tags: ['tag:cloud'] },
      { proto: 'tcp', port: 22 },
    ),
  ).toBe(true);
});

test('it refuses a host alias to a node at another address', () => {
  const filter = buildStubTailnetFilter({
    hosts: { server: '100.64.0.2' },
    grants: [{ src: ['*'], dst: ['server'], ip: ['*'] }],
  });

  expect(
    filter.canConnect(
      { ip: '100.64.0.1', roles: ['member'], tags: [] },
      { ip: '100.64.0.3', roles: [], tags: ['tag:cloud'] },
      { proto: 'tcp', port: 22 },
    ),
  ).toBe(false);
});

test('it allows a connection that any one grant matches, as grants only add access', () => {
  const filter = buildStubTailnetFilter({
    hosts: {},
    grants: [
      { src: ['*'], dst: ['*'], ip: ['tcp:443'] },
      { src: ['*'], dst: ['*'], ip: ['tcp:22'] },
    ],
  });

  expect(
    filter.canConnect(
      { ip: '100.64.0.1', roles: ['member'], tags: [] },
      { ip: '100.64.0.2', roles: ['member'], tags: [] },
      { proto: 'tcp', port: 22 },
    ),
  ).toBe(true);
});

test('it throws on a selector it does not model', () => {
  const filter = buildStubTailnetFilter({
    hosts: {},
    grants: [{ src: ['group:ops'], dst: ['*'], ip: ['*'] }],
  });

  expect(() =>
    filter.canConnect(
      { ip: '100.64.0.1', roles: ['member'], tags: [] },
      { ip: '100.64.0.2', roles: ['member'], tags: [] },
      { proto: 'tcp', port: 22 },
    ),
  ).toThrowWithMessage(Error, 'the stand-in does not model the selector group:ops');
});

test('it throws on a protocol it does not model', () => {
  const filter = buildStubTailnetFilter({
    hosts: {},
    grants: [{ src: ['*'], dst: ['*'], ip: ['gre:*'] }],
  });

  expect(() =>
    filter.canConnect(
      { ip: '100.64.0.1', roles: ['member'], tags: [] },
      { ip: '100.64.0.2', roles: ['member'], tags: [] },
      { proto: 'tcp', port: 22 },
    ),
  ).toThrowWithMessage(Error, 'the stand-in does not model the protocol gre');
});

test('it throws on a port entry it cannot read', () => {
  const filter = buildStubTailnetFilter({
    hosts: {},
    grants: [{ src: ['*'], dst: ['*'], ip: ['tcp:https'] }],
  });

  expect(() =>
    filter.canConnect(
      { ip: '100.64.0.1', roles: ['member'], tags: [] },
      { ip: '100.64.0.2', roles: ['member'], tags: [] },
      { proto: 'tcp', port: 22 },
    ),
  ).toThrowWithMessage(Error, 'the stand-in does not model the ip entry tcp:https');
});
