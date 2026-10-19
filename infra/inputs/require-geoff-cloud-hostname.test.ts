import { expect, test } from 'bun:test';
import { requireGeoffCloudHostname } from './require-geoff-cloud-hostname.ts';

test.each([['files.geoff.cloud'], ['a.b-c.geoff.cloud']])('it accepts %s', (hostname) => {
  expect(() => {
    requireGeoffCloudHostname('files.hostname', hostname);
  }).not.toThrow();
});

test.each([
  ['an unset value', undefined],
  ['the zone apex', 'geoff.cloud'],
  ['another zone', 'files.example.com'],
  ['a URL', 'https://files.geoff.cloud'],
  ['an upper-case name', 'Files.geoff.cloud'],
])('it refuses %s, naming the key', (_label, hostname) => {
  expect(() => {
    requireGeoffCloudHostname('files.hostname', hostname);
  }).toThrowWithMessage(Error, 'stack config "files.hostname" must name a host under geoff.cloud');
});
