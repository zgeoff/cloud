// the registry's answer for one manifest: the digest it names, that it serves none, or why it
// gave no answer
export type RegistryAnswer =
  | { readonly digest: string }
  | { readonly missing: true }
  | { readonly error: string };

// Asks an image's registry for the digest of one manifest, by tag or by digest, through the
// distribution API's manifest HEAD, with an anonymous pull token when the registry asks for one.
export async function tryReadManifestDigest(
  name: string,
  reference: string,
): Promise<RegistryAnswer> {
  try {
    return await readManifestDigest(name, reference);
  } catch (error) {
    return { error: error instanceof Error ? error.message : String(error) };
  }
}

// an image index or a single manifest, in OCI's or Docker's media type: the registry answers with
// the digest of whichever the tag names, which is what a pin holds
const manifestTypes = [
  'application/vnd.oci.image.index.v1+json',
  'application/vnd.docker.distribution.manifest.list.v2+json',
  'application/vnd.docker.distribution.manifest.v2+json',
  'application/vnd.oci.image.manifest.v1+json',
].join(', ');

// The distribution API's manifest HEAD. A registry that wants a token answers 401 with a Bearer
// challenge, and its realm hands out an anonymous pull token for a public image.
async function readManifestDigest(name: string, reference: string): Promise<RegistryAnswer> {
  const location = resolveRegistry(name);
  const url = `https://${location.host}/v2/${location.repository}/manifests/${reference}`;

  const first = await sendManifestHead(url, undefined);

  const response =
    first.status === 401
      ? await sendManifestHeadWithToken(url, first.headers.get('www-authenticate'))
      : first;

  if (response.status === 404) {
    return { missing: true };
  }

  if (response.status !== 200) {
    return { error: `the registry answered ${response.status}` };
  }

  const digest = response.headers.get('docker-content-digest');

  return digest === null ? { error: 'the registry named no digest' } : { digest };
}

// Docker Hub's names carry no host, and an official image's name no namespace
function resolveRegistry(name: string): { readonly host: string; readonly repository: string } {
  const [first = '', ...rest] = name.split('/');

  if (rest.length > 0 && (first.includes('.') || first.includes(':') || first === 'localhost')) {
    return { host: first, repository: rest.join('/') };
  }

  return { host: 'registry-1.docker.io', repository: rest.length > 0 ? name : `library/${name}` };
}

function sendManifestHead(url: string, token: string | undefined): Promise<Response> {
  return fetch(url, {
    method: 'HEAD',
    headers: {
      accept: manifestTypes,
      ...(token === undefined ? {} : { authorization: `Bearer ${token}` }),
    },
    signal: AbortSignal.timeout(15_000),
  });
}

async function sendManifestHeadWithToken(url: string, challenge: string | null): Promise<Response> {
  const token = await readPullToken(challenge);

  return sendManifestHead(url, token);
}

async function readPullToken(challenge: string | null): Promise<string> {
  const response = await fetch(buildTokenURL(challenge ?? ''), {
    signal: AbortSignal.timeout(15_000),
  });

  if (response.status !== 200) {
    throw new Error(`the token realm answered ${response.status}`);
  }

  const body: unknown = await response.json();

  const token = findToken(body);

  if (token === undefined) {
    throw new Error('the token realm answered without a token');
  }

  return token;
}

// the challenge's realm, asked for its service and scope
function buildTokenURL(challenge: string): URL {
  const parameters = parseChallenge(challenge);
  const realm = parameters.get('realm');

  if (realm === undefined) {
    throw new Error('the registry answered 401 without a Bearer realm');
  }

  const url = new URL(realm);

  for (const key of ['service', 'scope']) {
    const value = parameters.get(key);

    if (value !== undefined) {
      url.searchParams.set(key, value);
    }
  }

  return url;
}

// Bearer realm="…",service="…",scope="…" → its parameters; any other scheme has none
function parseChallenge(challenge: string): ReadonlyMap<string, string> {
  if (!/^bearer\s/iu.test(challenge)) {
    return new Map();
  }

  const parameters = new Map<string, string>();

  for (const match of challenge.matchAll(/(?<key>\w+)="(?<value>[^"]*)"/gu)) {
    parameters.set(match.groups?.['key'] ?? '', match.groups?.['value'] ?? '');
  }

  return parameters;
}

// a token realm answers with token, access_token, or both
function findToken(body: unknown): string | undefined {
  if (typeof body !== 'object' || body === null) {
    return undefined;
  }

  const fields: Readonly<Record<string, unknown>> = { ...body };
  const token = fields['token'] ?? fields['access_token'];

  return typeof token === 'string' && token !== '' ? token : undefined;
}
