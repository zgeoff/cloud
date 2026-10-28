import { randomUUID } from 'node:crypto';
import type { R2Object, R2ObjectBody } from '@cloudflare/workers-types';

// R2Object is a class in workers-types; the stand-in's objects are plain values of its shape
type R2ObjectFields = { [K in keyof R2Object]: R2Object[K] };

type StubR2ObjectBody = R2ObjectFields &
  Pick<R2ObjectBody, 'bodyUsed' | 'arrayBuffer' | 'bytes' | 'text'>;

interface StubR2Bucket {
  readonly objects: Map<string, string>;

  // R2's API names the lookup `get`, though it misses with null
  readonly get: (key: string) => Promise<StubR2ObjectBody | null>;
  readonly put: (key: string, value: string) => Promise<R2ObjectFields>;
}

export function buildStubR2Bucket(initial: Readonly<Record<string, string>> = {}): StubR2Bucket {
  const objects = new Map(Object.entries(initial));

  const metadata = new Map(
    Object.entries(initial).map(([key, value]) => [key, buildR2Object(key, value)]),
  );

  return {
    objects,
    get: (key) => {
      const value = objects.get(key);
      const object = metadata.get(key);

      if (value === undefined || object === undefined) {
        return Promise.resolve(null);
      }

      return Promise.resolve(buildR2ObjectBody(object, value));
    },
    put: (key, value) => {
      const object = buildR2Object(key, value);

      objects.set(key, value);
      metadata.set(key, object);

      return Promise.resolve(object);
    },
  };
}

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

// One Response holds the body, so it reads once as R2 does
function buildR2ObjectBody(object: R2ObjectFields, value: string): StubR2ObjectBody {
  const response = new Response(value);

  return {
    ...object,
    get bodyUsed() {
      return response.bodyUsed;
    },
    arrayBuffer: () => response.arrayBuffer(),
    bytes: () => response.bytes(),
    text: () => response.text(),
  };
}
