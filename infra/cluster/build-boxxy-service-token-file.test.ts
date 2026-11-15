import { expect, test } from 'bun:test';
import { buildBoxxyServiceTokenFile } from './build-boxxy-service-token-file.ts';

test("it gives each client the read scope and its one digest, for the door's /mcp", () => {
  const file = buildBoxxyServiceTokenFile('https://door.example.test', {
    'lighthouse-ro': '1111111111111111111111111111111111111111111111111111111111111111',
    'harbour-ro': '2222222222222222222222222222222222222222222222222222222222222222',
  });

  expect(JSON.parse(file)).toStrictEqual({
    resource: 'https://door.example.test/mcp',
    clients: {
      'lighthouse-ro': {
        scopes: ['read'],
        secretDigests: ['1111111111111111111111111111111111111111111111111111111111111111'],
      },
      'harbour-ro': {
        scopes: ['read'],
        secretDigests: ['2222222222222222222222222222222222222222222222222222222222222222'],
      },
    },
  });
});
