import { rmSync } from 'node:fs';
import { rename, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { ORPCError, implement } from '@orpc/server';
import type { UploadStore } from './create-upload-store.ts';
import { decideExpiry } from './decide-expiry.ts';
import { filesContract } from './files-contract.ts';
import type { UploadOutput } from './files-contract.ts';
import { isSafeFilename } from './is-safe-filename.ts';
import { mintFileID } from './mint-file-id.ts';
import { pickContentType, sniffLength } from './pick-content-type.ts';
import type { Role, Upload } from './types.ts';

// the largest file the service takes: Cloudflare's request body limit on the free plan
export const maxFileBytes = 100_000_000;

// space an upload leaves free, for the metadata file and its write-ahead log
const reserveBytes = 64 * 1024 * 1024;

export interface FilesRouterInputs {
  readonly store: UploadStore;

  // each upload's file, under its id
  readonly filesDir: string;

  // an upload's file while it is written, before it moves into filesDir
  readonly incomingDir: string;

  // the public origin, such as https://files.geoff.cloud, with no trailing slash
  readonly publicURL: string;
  readonly now: () => Date;

  // the bytes still free on the volume
  readonly readFreeBytes: () => number;
}

// the role the request's bearer token names, or undefined for no token or an unknown one
export interface FilesContext {
  readonly role: Role | undefined;
}

// The API's procedures. Every call needs a role token: owner may do everything, and agent may
// upload with an expiry of 30 days at most, and list, read and remove agent uploads only. An
// owner upload is not found for agent, and expire is the owner's alone.
export function buildFilesRouter(inputs: FilesRouterInputs) {
  const os = implement(filesContract)
    .$context<FilesContext>()
    .use((options) => {
      const role = options.context.role;

      if (role === undefined) {
        throw new ORPCError('UNAUTHORIZED', { message: 'a valid bearer token is required' });
      }

      return options.next({ context: { role } });
    });

  return os.router({
    upload: os.upload.handler(async (options) => {
      const input = options.input;
      const filename = input.filename ?? input.file.name;

      requireUploadAllowed(input.file, filename);

      const now = inputs.now();
      const expiresAt = requireExpiry(input.expires ?? '7d', options.context.role, now);

      if (inputs.readFreeBytes() < input.file.size + reserveBytes) {
        throw new ORPCError('INSUFFICIENT_STORAGE', { status: 507, message: 'the volume is full' });
      }

      const written = await writeFile(input.file, inputs);

      const upload = {
        ...written,
        filename,
        createdAt: now,
        uploader: options.context.role,
        label: input.label ?? null,
        link: input.link ?? null,
        expiresAt,
      };

      inputs.store.writeUpload(upload);

      return buildUploadOutput(upload, inputs.publicURL);
    }),
    list: os.list.handler((options) => {
      const uploads = inputs.store.collectUploads({
        ...(options.context.role === 'agent' ? { uploader: 'agent' as const } : {}),
        includeExpired: options.input.includeExpired ?? false,
        now: inputs.now(),
      });

      return uploads.map((upload) => buildUploadOutput(upload, inputs.publicURL));
    }),
    info: os.info.handler((options) => {
      const upload = requireVisibleUpload(inputs.store, options.input.id, options.context.role);

      return buildUploadOutput(upload, inputs.publicURL);
    }),
    expire: os.expire.handler((options) => {
      if (options.context.role !== 'owner') {
        throw new ORPCError('FORBIDDEN', { message: 'only the owner token changes an expiry' });
      }

      const upload = requireVisibleUpload(inputs.store, options.input.id, options.context.role);
      const expiresAt = requireExpiry(options.input.expires, options.context.role, inputs.now());

      inputs.store.updateExpiry(upload.id, expiresAt);

      return buildUploadOutput({ ...upload, expiresAt }, inputs.publicURL);
    }),
    remove: os.remove.handler((options) => {
      const upload = requireVisibleUpload(inputs.store, options.input.id, options.context.role);

      // the file first, then the row, as the sweep removes them
      rmSync(join(inputs.filesDir, upload.id), { force: true });

      inputs.store.removeUpload(upload.id);

      return { id: upload.id };
    }),
  });
}

function requireUploadAllowed(file: Blob, filename: string): void {
  if (!isSafeFilename(filename)) {
    throw new ORPCError('BAD_REQUEST', {
      message: 'filename must be 1 to 255 bytes, with no slash or control character',
    });
  }

  if (file.size > maxFileBytes) {
    throw new ORPCError('PAYLOAD_TOO_LARGE', {
      message: `a file holds ${maxFileBytes} bytes at most`,
    });
  }
}

function requireExpiry(expires: string, role: Role, now: Date): Date | null {
  const decision = decideExpiry({ expires, role, now });

  if (decision.outcome === 'invalid') {
    throw new ORPCError('BAD_REQUEST', { message: decision.reason });
  }

  if (decision.outcome === 'forbidden') {
    throw new ORPCError('FORBIDDEN', { message: decision.reason });
  }

  return decision.expiresAt;
}

interface WrittenFile {
  readonly id: string;
  readonly contentType: string;
  readonly size: number;
  readonly sha256: string;
}

// Writes the file into incomingDir, hashes it and reads its type, then moves it into filesDir
// under a new id, so filesDir never holds part of a file. A failed write leaves nothing behind.
async function writeFile(
  file: Blob,
  dirs: Pick<FilesRouterInputs, 'filesDir' | 'incomingDir'>,
): Promise<WrittenFile> {
  const id = mintFileID();
  const partPath = join(dirs.incomingDir, id);

  try {
    await Bun.write(partPath, file);

    const hasher = new Bun.CryptoHasher('sha256');

    for await (const chunk of file.stream()) {
      hasher.update(chunk);
    }

    const head = await Bun.file(partPath).slice(0, sniffLength).bytes();

    await rename(partPath, join(dirs.filesDir, id));

    return {
      id,
      contentType: pickContentType(head),
      size: file.size,
      sha256: hasher.digest('hex'),
    };
  } catch (error) {
    await rm(partPath, { force: true });

    throw error;
  }
}

// an agent never sees an owner upload, so it is not found rather than refused
function requireVisibleUpload(store: UploadStore, id: string, role: Role): Upload {
  const upload = store.findUpload(id);

  if (upload === null || (role === 'agent' && upload.uploader !== 'agent')) {
    throw new ORPCError('NOT_FOUND', { message: `no upload ${id}` });
  }

  return upload;
}

function buildUploadOutput(upload: Upload, publicURL: string): UploadOutput {
  return {
    id: upload.id,
    url: `${publicURL}/${upload.id}/${encodeURIComponent(upload.filename)}`,
    filename: upload.filename,
    contentType: upload.contentType,
    size: upload.size,
    sha256: upload.sha256,
    createdAt: upload.createdAt.toISOString(),
    uploader: upload.uploader,
    label: upload.label,
    link: upload.link,
    expiresAt: upload.expiresAt?.toISOString() ?? null,
  };
}
