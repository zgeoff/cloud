import { expect, test } from 'bun:test';
import { readFile } from 'node:fs/promises';
import { exposure, topology } from '@zgeoff/cloud-topology';
import invariant from 'tiny-invariant';
import { z } from 'zod';
import { buildNixieImpConfig } from './build-nixie-imp-config.ts';
import { buildNixieSpendStopConfig } from './build-nixie-spend-stop-config.ts';
import { renderNixieConfig } from './render-nixie-config.ts';

test('it adds the imp and spendStop sections to the config text as its last keys', () => {
  const spendStop = setupTest().spendStop;

  const imp = {
    url: 'https://imps.example.test',
    host_addresses: ['192.0.2.1/24'],
    egress_deny: [],
  };

  expect(renderNixieConfig('server:\n  port: 8080\n', { imp, spendStop })).toBe(
    'server:\n  port: 8080\nimp: {"url":"https://imps.example.test","host_addresses":["192.0.2.1/24"],"egress_deny":[]}\nspendStop: {"control":"http://192.0.2.1:8791","token":"deployment:gateway-control","modelURL":"http://192.0.2.2:8789"}\n',
  );
});

test('it starts the sections on their own lines when the text lacks a final newline', () => {
  const spendStop = setupTest().spendStop;
  const imp = { url: 'https://imps.example.test', host_addresses: [], egress_deny: [] };

  expect(renderNixieConfig('server:\n  port: 8080', { imp, spendStop })).toBe(
    'server:\n  port: 8080\nimp: {"url":"https://imps.example.test","host_addresses":[],"egress_deny":[]}\nspendStop: {"control":"http://192.0.2.1:8791","token":"deployment:gateway-control","modelURL":"http://192.0.2.2:8789"}\n',
  );
});

test('it renders deploy/nixie/config.yaml as YAML holding the file’s keys and the built sections', async () => {
  const text = await readFile(new URL('../../deploy/nixie/config.yaml', import.meta.url), 'utf8');

  const file: unknown = Bun.YAML.parse(text);
  const sections = setupTest().sections;
  const rendered: unknown = Bun.YAML.parse(renderNixieConfig(text, sections));

  invariant(typeof file === 'object' && file !== null, 'expected the file to parse as a mapping');

  expect(file).not.toContainKey('imp');
  expect(file).not.toContainKey('spendStop');
  expect(rendered).toStrictEqual({ ...file, ...sections });
});

test('it renders the conversation on Fable 5.2 with a 600k context and a 1-hour cache, and the checker with neither', async () => {
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
      'sonnet-5-5-high': profileSchema,
    }),
  });

  const sections = setupTest().sections;
  const rendered: unknown = Bun.YAML.parse(renderNixieConfig(text, sections));

  expect(z.object({ models: modelsSchema }).parse(rendered).models).toStrictEqual({
    roles: {
      conversation: 'fable-5-2',
      checker: 'sonnet-5-5-high',
      worker: 'sonnet-5-5',
    },
    profiles: {
      'fable-5-2': { model: 'claude-fable-5-2', context_tokens: 600_000, cache_ttl: '1h' },
      'sonnet-5-5-high': { model: 'claude-sonnet-5-5' },
    },
  });
});

function setupTest() {
  return {
    spendStop: {
      control: 'http://192.0.2.1:8791',
      token: 'deployment:gateway-control',
      modelURL: 'http://192.0.2.2:8789',
    },

    // the sections that infra renders into the ConfigMap from packages/topology
    sections: {
      imp: buildNixieImpConfig(topology),
      spendStop: buildNixieSpendStopConfig(topology, exposure),
    },
  };
}
