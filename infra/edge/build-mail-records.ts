import type { Output } from '@pulumi/pulumi';

interface MailRecordsInputs {
  readonly domain: string;
  readonly zoneID: Output<string>;
}

interface MailRecord {
  readonly name: string;
  readonly args: {
    readonly zoneId: Output<string>;
    readonly name: string;
    readonly type: 'MX' | 'CNAME' | 'TXT';
    readonly content: string;
    readonly priority?: number;
    readonly proxied: false;
    readonly ttl: 1;
  };
}

const fastmailDKIMSelectors = ['fm1', 'fm2', 'fm3'] as const;

// Cloudflare returns TXT content in quotes, so unquoted content would read as drift on each refresh
export function buildMailRecords(inputs: MailRecordsInputs): readonly MailRecord[] {
  const base = { zoneId: inputs.zoneID, proxied: false as const, ttl: 1 as const };

  return [
    {
      name: 'mail-mx-1',
      args: {
        ...base,
        name: inputs.domain,
        type: 'MX',
        content: 'eu1-smtp.messagingengine.com',
        priority: 10,
      },
    },
    {
      name: 'mail-mx-2',
      args: {
        ...base,
        name: inputs.domain,
        type: 'MX',
        content: 'eu2-smtp.messagingengine.com',
        priority: 20,
      },
    },
    ...fastmailDKIMSelectors.map((selector) => ({
      name: `mail-dkim-${selector}`,
      args: {
        ...base,
        name: `${selector}._domainkey.${inputs.domain}`,
        type: 'CNAME' as const,
        content: `${selector}.${inputs.domain}.dkim.fmhosted.com`,
      },
    })),
    {
      name: 'mail-spf',
      args: {
        ...base,
        name: inputs.domain,
        type: 'TXT',
        content: '"v=spf1 include:spf.messagingengine.com ?all"',
      },
    },
    {
      name: 'mail-dmarc',
      args: {
        ...base,
        name: `_dmarc.${inputs.domain}`,
        type: 'TXT',
        content: '"v=DMARC1; p=quarantine"',
      },
    },
  ];
}
