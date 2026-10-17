import { expect, test } from 'bun:test';
import { readFile } from 'node:fs/promises';
import { topology } from '@zgeoff/cloud-topology';
import { buildNixieImpConfig } from './build-nixie-imp-config.ts';
import { renderNixieConfig } from './render-nixie-config.ts';

test('it adds the imp section to the config text as its last key', () => {
  const imp = {
    url: 'https://imps.example.test',
    host_addresses: ['192.0.2.1/24'],
    egress_deny: [],
  };

  expect(renderNixieConfig('server:\n  port: 8080\n', imp)).toBe(
    'server:\n  port: 8080\nimp: {"url":"https://imps.example.test","host_addresses":["192.0.2.1/24"],"egress_deny":[]}\n',
  );
});

test('it starts the section on its own line when the text lacks a final newline', () => {
  const imp = { url: 'https://imps.example.test', host_addresses: [], egress_deny: [] };

  expect(renderNixieConfig('server:\n  port: 8080', imp)).toBe(
    'server:\n  port: 8080\nimp: {"url":"https://imps.example.test","host_addresses":[],"egress_deny":[]}\n',
  );
});

test('it renders deploy/nixie/config.yaml as YAML holding the file’s keys and the built imp section', async () => {
  const text = await readFile(new URL('../../deploy/nixie/config.yaml', import.meta.url), 'utf8');

  const file: unknown = Bun.YAML.parse(text);
  const rendered: unknown = Bun.YAML.parse(renderNixieConfig(text, buildNixieImpConfig(topology)));

  expect(file).not.toContainKey('imp');
  expect(rendered).toStrictEqual({ ...(file as object), imp: buildNixieImpConfig(topology) });
});
