import { findJSONField } from '../find-json-field.ts';
import type { ReleaseRead, ReleaseReadResult } from './read-release-values.ts';

// Reads the version's tarball from the npm registry, where the agent image fetches it, checks it
// against npm's dist.integrity and the version its package.json names, and gives its sha256. The
// GitHub release comes first, so a version npm lacks yet fails this run, and the next one pins it.
export async function readNPMTarballValues(
  read: ReleaseRead,
  packageName: string,
): Promise<ReleaseReadResult | Error> {
  const metadata = await readRegistry(`https://registry.npmjs.org/${packageName}/${read.version}`);

  if (metadata instanceof Error) {
    return metadata;
  }

  const dist = findJSONField(JSON.parse(new TextDecoder().decode(metadata)), 'dist');
  const integrity = findJSONField(dist, 'integrity');
  const url = `https://registry.npmjs.org/${packageName}/-/${packageName}-${read.version}.tgz`;

  if (findJSONField(dist, 'tarball') !== url || typeof integrity !== 'string') {
    return new Error(
      `npm lists ${packageName} ${read.version}'s tarball at ${String(findJSONField(dist, 'tarball'))}, not where the agent image fetches it`,
    );
  }

  const bytes = await readRegistry(url);

  return bytes instanceof Error ? bytes : checkTarball(read, { packageName, integrity, bytes });
}

async function readRegistry(url: string) {
  const response = await fetch(url);

  if (!response.ok) {
    return new Error(`the npm registry answered ${response.status} for ${url}`);
  }

  const body = await response.arrayBuffer();

  return new Uint8Array(body);
}

interface Tarball {
  readonly packageName: string;
  readonly integrity: string;
  readonly bytes: Uint8Array;
}

async function checkTarball(
  read: ReleaseRead,
  tarball: Tarball,
): Promise<ReleaseReadResult | Error> {
  const sha512 = new Bun.CryptoHasher('sha512').update(tarball.bytes).digest('base64');

  if (`sha512-${sha512}` !== tarball.integrity) {
    return new Error(`the tarball does not match ${tarball.integrity}`);
  }

  const version = await readPackagedVersion(tarball.bytes);

  if (version !== read.version) {
    return new Error(
      `the tarball holds ${tarball.packageName} ${String(version)}, not ${read.version}`,
    );
  }

  return {
    values: { tarballSum: new Bun.CryptoHasher('sha256').update(tarball.bytes).digest('hex') },
    flags: [],
  };
}

// the version that the tarball's package.json names, or null for a tarball without one
async function readPackagedVersion(bytes: Uint8Array) {
  const files = await new Bun.Archive(bytes).files('package/package.json').catch(() => null);

  const file = files?.get('package/package.json');
  const text = file === undefined ? 'null' : await file.text();
  const version = findJSONField(JSON.parse(text), 'version');

  return typeof version === 'string' ? version : null;
}
