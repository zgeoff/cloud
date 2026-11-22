import { expect, test } from 'bun:test';
import { collectPepysForwarderTrustFailures } from './collect-pepys-forwarder-trust-failures.ts';
import { readPepysTrustDocuments } from './read-pepys-trust-documents.ts';

function setupTest() {
  // the key of deploy/pepys/imp-issuers/geoffcloud.json, whose kid is its RFC 7638 thumbprint
  const impKey = {
    kty: 'EC',
    crv: 'P-256',
    x: 'GTYDWbDqusa_95TjCkuzS-aL_iBGJnEFRH2MBAbKFJ8',
    y: 'Rg0TemO3yFIBkShwuricjUqcf7im7HAlBY4yGnz8rfQ',
    kid: 'o5TLvUtvZZi_u8auk9gRNjSNVvjuUlagX8wR51eFrjE',
    alg: 'ES256',
    use: 'sig',
  };

  const keys = {
    forwarder: {
      ...impKey,
      x: 'b3JjaGFyZC1rZXkteC1jb29yZGluYXRlLWZvci10ZXN0',
      y: 'b3JjaGFyZC1rZXkteS1jb29yZGluYXRlLWZvci10ZXN0',
      kid: 'orchard-key',
    },
    impUnderAnotherKid: { ...impKey, kid: 'orchard-key' },
    rsa: { ...impKey, kty: 'RSA', kid: 'orchard-key' },
  };

  return {
    keys,
    imps: {
      'geoffcloud.json': JSON.stringify({ issuer: 'geoffcloud', keys: [impKey], retire: [] }),
    },
  };
}

type KeyName = 'forwarder' | 'impUnderAnotherKid' | 'rsa';

interface Row {
  readonly label: string;
  readonly file: string;
  readonly issuer: string;
  readonly key: KeyName;
  readonly failures: string[];
}

test.each<Row>([
  {
    label: 'a document named after its issuer',
    file: 'orchard-pc.json',
    issuer: 'orchard-pc',
    key: 'forwarder',
    failures: [],
  },
  {
    label: 'a document named after another issuer',
    file: 'orchard.json',
    issuer: 'orchard-pc',
    key: 'forwarder',
    failures: [
      'deploy/pepys/forwarder-issuers/orchard.json must be named orchard-pc.json, after its issuer',
    ],
  },
  {
    label: "an imp host's issuer name",
    file: 'geoffcloud.json',
    issuer: 'geoffcloud',
    key: 'forwarder',
    failures: [
      'deploy/pepys/forwarder-issuers/geoffcloud.json names the issuer geoffcloud, which an imp host has',
    ],
  },
  {
    label: "an imp host's key under another kid",
    file: 'orchard-pc.json',
    issuer: 'orchard-pc',
    key: 'impUnderAnotherKid',
    failures: [
      "deploy/pepys/forwarder-issuers/orchard-pc.json holds a key that an imp host's trust document holds",
    ],
  },
  {
    label: 'an issuer name with a space',
    file: 'orchard pc.json',
    issuer: 'orchard pc',
    key: 'forwarder',
    failures: [
      'deploy/pepys/forwarder-issuers/orchard pc.json is not a trust document that ingest loads',
    ],
  },
  {
    label: 'an RSA key',
    file: 'orchard-pc.json',
    issuer: 'orchard-pc',
    key: 'rsa',
    failures: [
      'deploy/pepys/forwarder-issuers/orchard-pc.json is not a trust document that ingest loads',
    ],
  },
])('it gives the failures of $label', (row: Row) => {
  const fixture = setupTest();

  const forwarders = {
    [row.file]: JSON.stringify({ issuer: row.issuer, keys: [fixture.keys[row.key]], retire: [] }),
  };

  expect(collectPepysForwarderTrustFailures(forwarders, fixture.imps)).toStrictEqual(row.failures);
});

test('it refuses a file that is not JSON', () => {
  const fixture = setupTest();

  expect(
    collectPepysForwarderTrustFailures({ 'orchard-pc.json': '{' }, fixture.imps),
  ).toStrictEqual([
    'deploy/pepys/forwarder-issuers/orchard-pc.json is not a trust document that ingest loads',
  ]);
});

test('it finds no failure in the trust documents that deploy/pepys holds', () => {
  expect(
    collectPepysForwarderTrustFailures(
      readPepysTrustDocuments('forwarder-issuers'),
      readPepysTrustDocuments('imp-issuers'),
    ),
  ).toStrictEqual([]);
});
