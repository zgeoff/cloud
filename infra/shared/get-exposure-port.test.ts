import { expect, test } from 'bun:test';
import { getExposurePort } from './get-exposure-port.ts';

test('it returns the port of the host-port entry with the name', () => {
  expect(
    getExposurePort(
      {
        entries: [
          {
            name: 'web-ingress',
            kind: 'host-port',
            protocol: 'tcp',
            port: 8443,
            scope: 'tailnet',
            reason: 'a web ingress',
          },
        ],
      },
      'web-ingress',
    ),
  ).toBe(8443);
});

test('it throws when no entry has the name', () => {
  expect(() => getExposurePort({ entries: [] }, 'web-ingress')).toThrowWithMessage(
    Error,
    'the exposure registry has no host-port entry web-ingress with a port',
  );
});

test('it throws when the entry with the name has no port', () => {
  expect(() =>
    getExposurePort(
      {
        entries: [
          {
            name: 'web-ingress',
            kind: 'tunnel-hostname',
            hostname: 'web.example.com',
            scope: 'reserved',
            reason: 'a later route',
          },
        ],
      },
      'web-ingress',
    ),
  ).toThrowWithMessage(
    Error,
    'the exposure registry has no host-port entry web-ingress with a port',
  );
});
