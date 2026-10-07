import { expect, test } from 'bun:test';
import { buildStubConfig } from './build-stub-config.ts';

test('it returns the raw string from get', () => {
  expect(buildStubConfig({ cluster: 'managed' }).get('cluster')).toBe('managed');
});

test('it returns the JSON text of an object from get, as Config does', () => {
  expect(buildStubConfig({ atcGateway: '{"image":"atc"}' }).get('atcGateway')).toBe(
    '{"image":"atc"}',
  );
});

test('it parses the JSON text from getObject', () => {
  const config = buildStubConfig({ atcGateway: '{"image":"atc","daemons":{"geoffcloud":{}}}' });

  expect(config.getObject<object>('atcGateway')).toStrictEqual({
    image: 'atc',
    daemons: { geoffcloud: {} },
  });
});

test('it reads an unset key as undefined from get', () => {
  expect(buildStubConfig({}).get('cluster')).toBeUndefined();
});

test('it reads an unset key as undefined from getObject', () => {
  expect(buildStubConfig({}).getObject<object>('atcGateway')).toBeUndefined();
});

test('it throws from getObject on a value that is not JSON', () => {
  const config = buildStubConfig({ atcGateway: 'not json' });

  expect(() => config.getObject<object>('atcGateway')).toThrow(SyntaxError);
});
