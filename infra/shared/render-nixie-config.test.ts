import { expect, test } from 'bun:test';
import { readFile } from 'node:fs/promises';
import { topology } from '@zgeoff/cloud-topology';
import invariant from 'tiny-invariant';
import { z } from 'zod';
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

  invariant(typeof file === 'object' && file !== null, 'expected the file to parse as a mapping');

  expect(file).not.toContainKey('imp');
  expect(rendered).toStrictEqual({ ...file, imp: buildNixieImpConfig(topology) });
});

test('it renders the conversation on Fable 5.2 with a 400k context and a 1-hour cache, and the memory writer and the checker with neither', async () => {
  const text = await readFile(new URL('../../deploy/nixie/config.yaml', import.meta.url), 'utf8');

  const profileSchema = z.object({
    model: z.string(),
    context_tokens: z.number().optional(),
    cache_ttl: z.string().optional(),
  });

  const modelsSchema = z.object({
    roles: z.record(z.string(), z.string()),
    profiles: z.object({
      'fable-5-2': profileSchema,
      'haiku-5-5-low': profileSchema,
      'sonnet-5-5-high': profileSchema,
    }),
  });

  const rendered: unknown = Bun.YAML.parse(renderNixieConfig(text, buildNixieImpConfig(topology)));

  expect(z.object({ models: modelsSchema }).parse(rendered).models).toStrictEqual({
    roles: {
      conversation: 'fable-5-2',
      'memory-writer': 'haiku-5-5-low',
      checker: 'sonnet-5-5-high',
    },
    profiles: {
      'fable-5-2': { model: 'claude-fable-5-2', context_tokens: 400_000, cache_ttl: '1h' },
      'haiku-5-5-low': { model: 'claude-haiku-5-5' },
      'sonnet-5-5-high': { model: 'claude-sonnet-5-5' },
    },
  });
});
