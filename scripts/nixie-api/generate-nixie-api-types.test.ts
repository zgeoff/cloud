import { expect, test } from 'bun:test';
import { join } from 'node:path';
import { generateNixieAPITypes } from './generate-nixie-api-types.ts';

test('it renders one procedure of a contract document as its path, input and outputs', async () => {
  const types = await generateNixieAPITypes(
    JSON.stringify({
      openapi: '3.1.1',
      info: { title: 'nixie', version: '0' },
      paths: {
        '/sessions/revoke': {
          post: {
            operationId: 'sessions.revoke',
            requestBody: {
              required: true,
              content: {
                'application/json': {
                  schema: {
                    type: 'object',
                    properties: { sessionID: { type: 'string' } },
                    required: ['sessionID'],
                  },
                },
              },
            },
            responses: { '200': { description: 'OK' } },
          },
        },
      },
    }),
  );

  expect(types).toMatchInlineSnapshot(`
    "// Generated from openapi.json beside it by \`bun run nixie:openapi <tag>\`: never edit it by hand.

    export interface paths {
        "/sessions/revoke": {
            parameters: {
                query?: never;
                header?: never;
                path?: never;
                cookie?: never;
            };
            get?: never;
            put?: never;
            post: operations["sessions.revoke"];
            delete?: never;
            options?: never;
            head?: never;
            patch?: never;
            trace?: never;
        };
    }
    export type webhooks = Record<string, never>;
    export interface components {
        schemas: never;
        responses: never;
        parameters: never;
        requestBodies: never;
        headers: never;
        pathItems: never;
    }
    export type $defs = Record<string, never>;
    export interface operations {
        "sessions.revoke": {
            parameters: {
                query?: never;
                header?: never;
                path?: never;
                cookie?: never;
            };
            requestBody: {
                content: {
                    "application/json": {
                        sessionID: string;
                    };
                };
            };
            responses: {
                /** @description OK */
                200: {
                    headers: {
                        [name: string]: unknown;
                    };
                    content?: never;
                };
            };
        };
    }
    "
  `);
});

test('it keeps the committed types in step with the committed contract document', async () => {
  const document = await Bun.file(join(import.meta.dir, 'openapi.json')).text();
  const types = await generateNixieAPITypes(document);
  const committed = await Bun.file(join(import.meta.dir, 'openapi.d.ts')).text();

  expect(types).toBe(committed);
});
