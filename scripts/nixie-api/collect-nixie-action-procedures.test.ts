import { expect, test } from 'bun:test';
import { collectNixieActionProcedures } from './collect-nixie-action-procedures.ts';

test('it collects each procedure whose input takes a client action ID, under either name', () => {
  const document = {
    paths: {
      '/conversation/read': {
        post: {
          requestBody: {
            content: {
              'application/json': {
                schema: { type: 'object', properties: { thread: { type: 'string' } } },
              },
            },
          },
        },
      },
      '/conversation/send': {
        post: {
          requestBody: {
            content: {
              'application/json': {
                schema: {
                  type: 'object',
                  properties: { clientMessageId: { type: 'string' }, text: { type: 'string' } },
                },
              },
            },
          },
        },
      },
      '/sessions/revoke': {
        post: {
          requestBody: {
            content: {
              'application/json': {
                schema: {
                  type: 'object',
                  properties: {
                    clientActionID: { type: 'string', format: 'uuid' },
                    sessionID: { type: 'string', format: 'uuid' },
                  },
                },
              },
            },
          },
        },
      },
      '/sessions/list': { post: {} },
    },
  };

  expect(collectNixieActionProcedures(document)).toStrictEqual([
    'conversation/send',
    'sessions/revoke',
  ]);
});

test('it collects nothing from a document without paths', () => {
  expect(collectNixieActionProcedures({ openapi: '3.1.1' })).toStrictEqual([]);
});
