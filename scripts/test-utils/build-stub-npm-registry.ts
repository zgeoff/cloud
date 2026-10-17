import type { RequestHandler } from 'msw';
import { HttpResponse, http } from 'msw';

// MSW handlers that stand in for registry.npmjs.org: a version's metadata at /<package>/<version>
// with dist.tarball and dist.integrity, and the tarball at /<package>/-/<package>-<version>.tgz.
// A version it lacks answers 404, the status the real registry sent on 2026-10-13.
export interface StubNPMVersion {
  readonly tarball: Uint8Array;

  // where the metadata says the tarball is, when it is not the registry's own place
  readonly tarballURL?: string;
}

export function buildStubNPMRegistry(
  packages: Readonly<Record<string, Readonly<Record<string, StubNPMVersion>>>>,
): RequestHandler[] {
  return [
    http.get('https://registry.npmjs.org/:name/:version', (info) => {
      const name = String(info.params['name']);
      const version = String(info.params['version']);
      const found = packages[name]?.[version];

      return found === undefined
        ? HttpResponse.json({ error: `version not found: ${version}` }, { status: 404 })
        : HttpResponse.json(buildMetadata(name, version, found));
    }),
    http.get('https://registry.npmjs.org/:name/-/:file', (info) => {
      const name = String(info.params['name']);
      const version = String(info.params['file']).slice(name.length + 1, -'.tgz'.length);
      const found = packages[name]?.[version];

      return found === undefined
        ? HttpResponse.json({ error: 'Not found' }, { status: 404 })
        : new HttpResponse(found.tarball, {
            headers: { 'content-type': 'application/octet-stream' },
          });
    }),
  ];
}

function buildMetadata(name: string, version: string, found: StubNPMVersion) {
  const integrity = new Bun.CryptoHasher('sha512').update(found.tarball).digest('base64');

  const tarball = found.tarballURL ?? `https://registry.npmjs.org/${name}/-/${name}-${version}.tgz`;

  return { name, version, dist: { tarball, integrity: `sha512-${integrity}` } };
}
