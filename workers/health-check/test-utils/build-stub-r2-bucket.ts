import { randomUUID } from 'node:crypto';
import type {
  R2Bucket,
  R2GetOptions,
  R2Object,
  R2ObjectBody,
  R2PutOptions,
} from '@cloudflare/workers-types';

interface StubR2Bucket extends Pick<R2Bucket, 'get' | 'put'> {
  readonly objects: Map<string, string>;
}

// Stand-in for R2 get/put over an in-memory text map, typed by @cloudflare/workers-types
export function buildStubR2Bucket(initial: Readonly<Record<string, string>> = {}): StubR2Bucket {
  const objects = new Map(Object.entries(initial));

  const metadata = new Map(
    Object.entries(initial).map(([key, value]) => [key, buildR2Object(key, value)]),
  );

  return {
    objects,
    get: (key: string, options?: R2GetOptions): Promise<R2ObjectBody | null> => {
      if (options !== undefined) {
        return Promise.reject(new Error('the stub R2 bucket does not model get options'));
      }

      const value = objects.get(key);
      const object = metadata.get(key);

      if (value === undefined || object === undefined) {
        return Promise.resolve(null);
      }

      return Promise.resolve(buildR2ObjectBody(object, value));
    },
    put: (
      key: string,
      value: Parameters<R2Bucket['put']>[1],
      options?: R2PutOptions,
    ): Promise<R2Object> => {
      if (typeof value !== 'string' || options !== undefined) {
        return Promise.reject(
          new Error('the stub R2 bucket models only a string value with no options'),
        );
      }

      const object = buildR2Object(key, value);

      objects.set(key, value);
      metadata.set(key, object);

      return Promise.resolve(object);
    },
  };
}

// R2Object is a class in workers-types; the stand-in's objects are plain values of its shape
type R2ObjectFields = { [K in keyof R2Object]: R2Object[K] };

function buildR2Object(key: string, value: string): R2ObjectFields {
  const md5 = new Bun.CryptoHasher('md5').update(value);

  const etag = md5.copy().digest('hex');

  return {
    key,
    version: randomUUID().replaceAll('-', ''),
    size: new TextEncoder().encode(value).byteLength,
    etag,
    httpEtag: `"${etag}"`,
    checksums: {
      md5: new Uint8Array(md5.digest()).buffer,
      toJSON: () => ({ md5: etag }),
    },
    uploaded: new Date(),
    httpMetadata: {},
    customMetadata: {},
    storageClass: 'Standard',
    writeHttpMetadata: () => {
      // the stand-in stores no httpMetadata, so there is no header to write
    },
  };
}

type R2Blob = Awaited<ReturnType<R2ObjectBody['blob']>>;

type R2ReadableStream = R2ObjectBody['body'];

// One Response holds the body, so it reads once as R2 does. Bun's ReadableStream/Blob
// reader overloads differ from workers-types', and R2's json() types its value as the
// caller's T unchecked, so the stand-in asserts those three types.
/* oxlint-disable typescript/no-unsafe-type-assertion */
function buildR2ObjectBody(object: R2ObjectFields, value: string): R2ObjectBody {
  const response = new Response(value);

  const body = response.body;

  if (body === null) {
    throw new Error('a Response built from a string has a body');
  }

  return {
    ...object,
    get body() {
      return body as unknown as R2ReadableStream;
    },
    get bodyUsed() {
      return response.bodyUsed;
    },
    arrayBuffer: () => response.arrayBuffer(),
    bytes: () => response.bytes(),
    text: () => response.text(),
    json: <T>() => response.json() as Promise<T>,
    blob: () => response.blob() as Promise<unknown> as Promise<R2Blob>,
  };
}

/* oxlint-enable typescript/no-unsafe-type-assertion */
