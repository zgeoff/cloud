// the first test parses one entry of each kind as one literal, so its body is long
/* oxlint-disable max-lines-per-function */
import { expect, test } from 'bun:test';
import { exposureSchema } from './exposure-schema.ts';
import type { Exposure } from './exposure-schema.ts';

test('it accepts one entry of each kind as given', () => {
  const payload: Exposure = {
    entries: [
      {
        name: 'tailscale',
        kind: 'host-port',
        protocol: 'udp',
        port: 41_641,
        scope: 'public',
        edge: 'Tailscale direct connections',
        reason: 'direct connections',
      },
      {
        name: 'icmp',
        kind: 'host-port',
        protocol: 'icmp',
        scope: 'public',
        edge: 'ICMP',
        reason: 'ping',
      },
      {
        name: 'relay',
        kind: 'host-port',
        protocol: 'tcp',
        port: 18_081,
        scope: 'host',
        interface: 'docker0',
        admission: true,
        reason: 'the relay',
      },
      {
        name: 'ssh',
        kind: 'host-port',
        protocol: 'tcp',
        port: 22,
        scope: 'tailnet',
        reason: 'ssh',
        ticket: 'GEO-420',
      },
      {
        name: 'atc',
        kind: 'tunnel-hostname',
        hostname: 'atc.example.org',
        scope: 'public',
        reason: 'the gateway',
        auth: 'an OAuth server',
      },
      {
        name: 'funnel',
        kind: 'tailnet-capability',
        attr: 'funnel',
        scope: 'public',
        reason: 'funnel',
        auth: 'a bearer token',
      },
      {
        name: 'worker',
        kind: 'worker-url',
        script: 'health-check',
        scope: 'closed',
        reason: 'cron only',
      },
    ],
  };

  expect(exposureSchema.safeParse(payload).data).toStrictEqual(payload);
});

test('it rejects a second entry with the same name', () => {
  const result = exposureSchema.safeParse({
    entries: [
      {
        name: 'ssh',
        kind: 'host-port',
        protocol: 'tcp',
        port: 22,
        scope: 'tailnet',
        reason: 'ssh',
      },
      {
        name: 'ssh',
        kind: 'host-port',
        protocol: 'tcp',
        port: 2222,
        scope: 'tailnet',
        reason: 'ssh',
      },
    ],
  });

  expect(result.error?.issues).toPartiallyContain({ path: ['entries', 1, 'name'] });
});

test('it rejects an entry without a reason', () => {
  const result = exposureSchema.safeParse({
    entries: [
      { name: 'ssh', kind: 'host-port', protocol: 'tcp', port: 22, scope: 'tailnet', reason: '' },
    ],
  });

  expect(result.error?.issues).toPartiallyContain({ path: ['entries', 0, 'reason'] });
});

test('it rejects a key that the schema does not name', () => {
  const result = exposureSchema.safeParse({
    entries: [
      {
        name: 'ssh',
        kind: 'host-port',
        protocol: 'tcp',
        port: 22,
        scope: 'tailnet',
        reason: 'ssh',
        open: true,
      },
    ],
  });

  expect(result.error?.issues).toPartiallyContain({
    code: 'unrecognized_keys',
    path: ['entries', 0],
  });
});

test.each([
  [
    'an icmp entry with a port',
    {
      name: 'icmp',
      kind: 'host-port',
      protocol: 'icmp',
      port: 1,
      scope: 'public',
      edge: 'ICMP',
      reason: 'ping',
    },
    'port',
  ],
  [
    'a tcp entry without a port',
    { name: 'ssh', kind: 'host-port', protocol: 'tcp', scope: 'tailnet', reason: 'ssh' },
    'port',
  ],
  [
    'a host-scope entry without an interface',
    {
      name: 'relay',
      kind: 'host-port',
      protocol: 'tcp',
      port: 18_081,
      scope: 'host',
      reason: 'the relay',
    },
    'interface',
  ],
  [
    'a tailnet-scope entry with an interface',
    {
      name: 'ssh',
      kind: 'host-port',
      protocol: 'tcp',
      port: 22,
      scope: 'tailnet',
      interface: 'eth0',
      reason: 'ssh',
    },
    'interface',
  ],
  [
    'a public entry without an edge rule description',
    {
      name: 'tailscale',
      kind: 'host-port',
      protocol: 'udp',
      port: 41_641,
      scope: 'public',
      reason: 'direct',
    },
    'edge',
  ],
  [
    'a tailnet-scope entry with an edge rule description',
    {
      name: 'ssh',
      kind: 'host-port',
      protocol: 'tcp',
      port: 22,
      scope: 'tailnet',
      edge: 'SSH',
      reason: 'ssh',
    },
    'edge',
  ],
  [
    'an admission outside host scope',
    {
      name: 'ssh',
      kind: 'host-port',
      protocol: 'tcp',
      port: 22,
      scope: 'tailnet',
      admission: true,
      reason: 'ssh',
    },
    'admission',
  ],
  [
    'a public tunnel hostname without an auth layer',
    {
      name: 'files',
      kind: 'tunnel-hostname',
      hostname: 'files.example.org',
      scope: 'public',
      reason: 'file sharing',
    },
    'auth',
  ],
  [
    'a public tailnet capability without an auth layer',
    { name: 'funnel', kind: 'tailnet-capability', attr: 'funnel', scope: 'public', reason: 'f' },
    'auth',
  ],
  [
    'a public worker URL without an auth layer',
    { name: 'worker', kind: 'worker-url', script: 'upload', scope: 'public', reason: 'uploads' },
    'auth',
  ],
  [
    'a reserved tunnel hostname with an auth layer',
    {
      name: 'mcp',
      kind: 'tunnel-hostname',
      hostname: 'mcp.example.org',
      scope: 'reserved',
      reason: 'held',
      auth: 'an OAuth server',
    },
    'auth',
  ],
  [
    'a reserved host port',
    { name: 'ssh', kind: 'host-port', protocol: 'tcp', port: 22, scope: 'reserved', reason: 'ssh' },
    'scope',
  ],
])('it rejects %s', (_label: string, entry: unknown, field: string) => {
  const result = exposureSchema.safeParse({ entries: [entry] });

  expect(result.error?.issues).toPartiallyContain({ path: ['entries', 0, field] });
});
