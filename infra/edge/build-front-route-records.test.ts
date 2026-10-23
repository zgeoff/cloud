import { expect, test } from 'bun:test';
import { output } from '@pulumi/pulumi';
import { buildFrontRouteRecords } from './build-front-route-records.ts';

test('it points a DNS-only A and AAAA record at the host for each public front route', () => {
  const zoneID = output('zone-0a1b2c3d');

  expect(
    buildFrontRouteRecords({
      entries: [
        {
          name: 'notes',
          kind: 'front-route',
          hostname: 'notes.example.org',
          upstream: '127.0.0.1:8080',
          paths: ['/notes'],
          scope: 'public',
          reason: 'the notes API',
          auth: 'a bearer token',
        },
      ],
      zoneID,
      ipv4: '192.0.2.10',
      ipv6: '2001:db8::10',
    }),
  ).toStrictEqual([
    {
      name: 'front-notes-v4',
      args: {
        zoneId: zoneID,
        name: 'notes.example.org',
        type: 'A',
        content: '192.0.2.10',
        proxied: false,
        ttl: 1,
      },
    },
    {
      name: 'front-notes-v6',
      args: {
        zoneId: zoneID,
        name: 'notes.example.org',
        type: 'AAAA',
        content: '2001:db8::10',
        proxied: false,
        ttl: 1,
      },
    },
  ]);
});

test('it makes no record for a reserved front route or an entry of another kind', () => {
  expect(
    buildFrontRouteRecords({
      entries: [
        {
          name: 'notes',
          kind: 'front-route',
          hostname: 'notes.example.org',
          upstream: '127.0.0.1:8080',
          paths: ['/notes'],
          scope: 'reserved',
          reason: 'held',
        },
        {
          name: 'files',
          kind: 'tunnel-hostname',
          hostname: 'files.example.org',
          scope: 'public',
          reason: 'file sharing',
          auth: 'a bearer token',
        },
        {
          name: 'front',
          kind: 'host-port',
          protocol: 'tcp',
          port: 443,
          scope: 'public',
          edge: 'HTTPS',
          reason: 'the front',
        },
      ],
      zoneID: output('zone-0a1b2c3d'),
      ipv4: '192.0.2.10',
      ipv6: '2001:db8::10',
    }),
  ).toStrictEqual([]);
});
