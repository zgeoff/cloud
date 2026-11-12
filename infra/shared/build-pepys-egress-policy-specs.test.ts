import { expect, test } from 'bun:test';
import { buildPepysEgressPolicySpecs } from './build-pepys-egress-policy-specs.ts';

function setupTest() {
  const dns = {
    to: [
      {
        namespaceSelector: { matchLabels: { 'kubernetes.io/metadata.name': 'kube-system' } },
        podSelector: { matchLabels: { 'k8s-app': 'kube-dns' } },
      },
    ],
    ports: [
      { protocol: 'UDP', port: 53 },
      { protocol: 'TCP', port: 53 },
    ],
  };

  const internetOn443 = {
    to: [
      {
        ipBlock: {
          cidr: '0.0.0.0/0',
          except: [
            '10.42.0.0/16',
            '10.43.0.0/16',
            '100.64.0.0/10',
            '10.88.0.0/16',
            '10.0.0.0/8',
            '172.16.0.0/12',
            '192.168.0.0/16',
            '169.254.0.0/16',
          ],
        },
      },
    ],
    ports: [{ protocol: 'TCP', port: 443 }],
  };

  return { dns, internetOn443 };
}

test('it names one egress policy for each pepys workload', () => {
  expect(Object.keys(buildPepysEgressPolicySpecs())).toStrictEqual([
    'pepys-garage-egress',
    'pepys-s2-egress',
    'pepys-ingest-egress',
    'pepys-host-egress',
    'pepys-backup-egress',
  ]);
});

test('it lets Garage dial nothing, since its RPC address is loopback', () => {
  expect(buildPepysEgressPolicySpecs()['pepys-garage-egress']).toStrictEqual({
    podSelector: { matchLabels: { app: 'pepys-garage' } },
    policyTypes: ['Egress'],
    egress: [],
  });
});

test('it lets s2-lite reach DNS and Garage on the S3 port', () => {
  const ctx = setupTest();

  expect(buildPepysEgressPolicySpecs()['pepys-s2-egress']).toStrictEqual({
    podSelector: { matchLabels: { app: 'pepys-s2' } },
    policyTypes: ['Egress'],
    egress: [
      ctx.dns,
      {
        to: [{ podSelector: { matchLabels: { app: 'pepys-garage' } } }],
        ports: [{ protocol: 'TCP', port: 3900 }],
      },
    ],
  });
});

test('it lets ingest reach DNS, s2-lite, and the internet on 443 only, outside the tailnet, the private ranges and link-local', () => {
  const ctx = setupTest();

  expect(buildPepysEgressPolicySpecs()['pepys-ingest-egress']).toStrictEqual({
    podSelector: { matchLabels: { app: 'pepys-ingest' } },
    policyTypes: ['Egress'],
    egress: [
      ctx.dns,
      {
        to: [{ podSelector: { matchLabels: { app: 'pepys-s2' } } }],
        ports: [{ protocol: 'TCP', port: 8080 }],
      },
      ctx.internetOn443,
    ],
  });
});

test('it lets the host and the API reach DNS and s2-lite only', () => {
  const ctx = setupTest();

  expect(buildPepysEgressPolicySpecs()['pepys-host-egress']).toStrictEqual({
    podSelector: { matchLabels: { app: 'pepys-host' } },
    policyTypes: ['Egress'],
    egress: [
      ctx.dns,
      {
        to: [{ podSelector: { matchLabels: { app: 'pepys-s2' } } }],
        ports: [{ protocol: 'TCP', port: 8080 }],
      },
    ],
  });
});

test("it lets the backup reach DNS, Garage, and the internet on 443 for R2's bucket", () => {
  const ctx = setupTest();

  expect(buildPepysEgressPolicySpecs()['pepys-backup-egress']).toStrictEqual({
    podSelector: { matchLabels: { app: 'pepys-backup' } },
    policyTypes: ['Egress'],
    egress: [
      ctx.dns,
      {
        to: [{ podSelector: { matchLabels: { app: 'pepys-garage' } } }],
        ports: [{ protocol: 'TCP', port: 3900 }],
      },
      ctx.internetOn443,
    ],
  });
});
