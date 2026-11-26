import { expect, test } from 'bun:test';
import { output } from '@pulumi/pulumi';
import { buildMailRecords } from './build-mail-records.ts';

test("it declares Fastmail's MX, DKIM and SPF records and a quarantine DMARC policy, all DNS only", () => {
  const zoneID = output('zone-7f3e9a1c');

  expect(buildMailRecords({ domain: 'mail.example.net', zoneID })).toStrictEqual([
    {
      name: 'mail-mx-1',
      args: {
        zoneId: zoneID,
        name: 'mail.example.net',
        type: 'MX',
        content: 'eu1-smtp.messagingengine.com',
        priority: 10,
        proxied: false,
        ttl: 1,
      },
    },
    {
      name: 'mail-mx-2',
      args: {
        zoneId: zoneID,
        name: 'mail.example.net',
        type: 'MX',
        content: 'eu2-smtp.messagingengine.com',
        priority: 20,
        proxied: false,
        ttl: 1,
      },
    },
    {
      name: 'mail-dkim-fm1',
      args: {
        zoneId: zoneID,
        name: 'fm1._domainkey.mail.example.net',
        type: 'CNAME',
        content: 'fm1.mail.example.net.dkim.fmhosted.com',
        proxied: false,
        ttl: 1,
      },
    },
    {
      name: 'mail-dkim-fm2',
      args: {
        zoneId: zoneID,
        name: 'fm2._domainkey.mail.example.net',
        type: 'CNAME',
        content: 'fm2.mail.example.net.dkim.fmhosted.com',
        proxied: false,
        ttl: 1,
      },
    },
    {
      name: 'mail-dkim-fm3',
      args: {
        zoneId: zoneID,
        name: 'fm3._domainkey.mail.example.net',
        type: 'CNAME',
        content: 'fm3.mail.example.net.dkim.fmhosted.com',
        proxied: false,
        ttl: 1,
      },
    },
    {
      name: 'mail-spf',
      args: {
        zoneId: zoneID,
        name: 'mail.example.net',
        type: 'TXT',
        content: '"v=spf1 include:spf.messagingengine.com ?all"',
        proxied: false,
        ttl: 1,
      },
    },
    {
      name: 'mail-dmarc',
      args: {
        zoneId: zoneID,
        name: '_dmarc.mail.example.net',
        type: 'TXT',
        content: '"v=DMARC1; p=quarantine"',
        proxied: false,
        ttl: 1,
      },
    },
  ]);
});
