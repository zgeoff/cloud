import { mkdirSync, readdirSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { OpenAPIHandler } from '@orpc/openapi/fetch';
import { Elysia } from 'elysia';
import { buildFileHeaders } from './build-file-headers.ts';
import type { UploadStore } from './create-upload-store.ts';
import { findTokenRole } from './find-token-role.ts';
import type { TokenHashes } from './find-token-role.ts';
import { implementFilesRouter, maxFileBytes } from './implement-files-router.ts';
import { fileIDLength } from './mint-file-id.ts';

export interface FilesServiceInputs {
  readonly store: UploadStore;

  // the volume: each upload's file under files/, and a file being written under incoming/
  readonly dataDir: string;
  readonly tokenHashes: TokenHashes;

  // the public origin, such as https://files.geoff.cloud, with no trailing slash
  readonly publicURL: string;
  readonly now: () => Date;
  readonly readFreeBytes: () => number;

  // writes an upload's bytes to a path on the volume, as Bun.write does
  readonly writeBytes: (path: string, file: Blob) => Promise<unknown>;
}

// On every response, the API's and the 404s included: no browser guesses a type, and no response
// runs script or loads anything. Cloudflare's zone raises any shorter max-age to its 4-hour browser
// TTL and caches a 404, but it never stores a no-store response, so a removal shows at once.
const everyResponseHeaders = {
  'X-Content-Type-Options': 'nosniff',
  'Content-Security-Policy': "default-src 'none'; sandbox",
  'Cache-Control': 'no-store',
};

// the largest request body Bun reads: the largest file, and room for the form around it
const maxRequestBodyBytes = maxFileBytes + 1024 * 1024;

interface RequestContext {
  readonly request: Request;
}

export function createFilesService(inputs: FilesServiceInputs) {
  const filesDir = join(inputs.dataDir, 'files');
  const incomingDir = join(inputs.dataDir, 'incoming');

  mkdirSync(filesDir, { recursive: true });
  rmSync(incomingDir, { recursive: true, force: true });
  mkdirSync(incomingDir);
  removeFilesWithoutRows(inputs.store, filesDir);

  const api = new OpenAPIHandler(
    implementFilesRouter({
      store: inputs.store,
      filesDir,
      incomingDir,
      publicURL: inputs.publicURL,
      now: inputs.now,
      readFreeBytes: inputs.readFreeBytes,
      writeBytes: inputs.writeBytes,
    }),
  );

  const sendToAPI = async (context: RequestContext): Promise<Response> => {
    const authorization = context.request.headers.get('Authorization');

    const result = await api.handle(context.request, {
      prefix: '/api',
      context: { role: findTokenRole(authorization, inputs.tokenHashes) },
    });

    return result.response ?? new Response('NOT_FOUND', { status: 404 });
  };

  // static API routes, since Elysia prefers /:id/:filename to a wildcard of the same depth; oRPC
  // reads the body itself
  return new Elysia({ serve: { maxRequestBodySize: maxRequestBodyBytes } })
    .onRequest((context) => {
      Object.assign(context.set.headers, everyResponseHeaders);
    })
    .get('/healthz', () => 'ok')
    .all('/api/files', sendToAPI, { parse: 'none' })
    .all('/api/files/*', sendToAPI, { parse: 'none' })
    .get('/:id/:filename', (context) => readFileResponse({ ...inputs, filesDir }, context.params));
}

// A stopped run can leave a file moved into place whose row it never wrote. Nothing lists, serves
// or sweeps such a file, so it goes before the service takes requests.
function removeFilesWithoutRows(store: UploadStore, filesDir: string): void {
  for (const id of readdirSync(filesDir)) {
    if (store.findUpload(id) === null) {
      rmSync(join(filesDir, id), { force: true });
    }
  }
}

const fileIDPattern = new RegExp(`^[A-Za-z\\d]{${fileIDLength}}$`, 'u');

type FileReadInputs = Pick<FilesServiceInputs, 'store' | 'now'> & { readonly filesDir: string };

interface FileParams {
  readonly id: string;
  readonly filename: string;
}

async function readFileResponse(inputs: FileReadInputs, params: FileParams): Promise<Response> {
  const upload = fileIDPattern.test(params.id) ? inputs.store.findUpload(params.id) : null;
  const file = Bun.file(join(inputs.filesDir, params.id));

  if (
    upload === null ||
    upload.filename !== params.filename ||
    (upload.expiresAt !== null && upload.expiresAt.getTime() <= inputs.now().getTime()) ||
    !(await file.exists())
  ) {
    return new Response('NOT_FOUND', { status: 404 });
  }

  return new Response(file, { headers: buildFileHeaders(upload) });
}
