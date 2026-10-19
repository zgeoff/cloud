export type RegistryAnswer =
  | { readonly digest: string }
  | { readonly missing: true }
  | { readonly error: string };

export async function tryReadManifestDigest(
  name: string,
  reference: string,
  githubToken?: string,
): Promise<RegistryAnswer> {
  try {
    return await readManifestDigest(name, reference, githubToken);
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

async function readManifestDigest(
  name: string,
  reference: string,
  githubToken: string | undefined,
): Promise<RegistryAnswer> {
  const location = resolveRegistry(name);
  const url = `https://${location.host}/v2/${location.repository}/manifests/${reference}`;

  const first = await sendManifestHead(url, undefined);

  // another registry may name ghcr.io's realm in its challenge, and would get the pull token
  const realmToken = location.host === 'ghcr.io' ? githubToken : undefined;

  // a registry that wants a token answers 401 with a Bearer challenge, whose realm hands out a
  // pull token
  const response =
    first.status === 401
      ? await sendManifestHeadWithToken(url, first.headers.get('www-authenticate'), realmToken)
      : first;

  return toRegistryAnswer(response.status, response.headers.get('docker-content-digest'));
}

function toRegistryAnswer(status: number, digest: string | null): RegistryAnswer {
  if (status === 404) {
    return { missing: true };
  }

  // ghcr.io answers 401 or 403 when the token cannot read a private package
  if (status === 401 || status === 403) {
    return { error: `the registry answered ${status}: the credential cannot read it` };
  }

  if (status !== 200) {
    return { error: `the registry answered ${status}` };
  }

  return digest === null ? { error: 'the registry named no digest' } : { digest };
}

function resolveRegistry(name: string): { readonly host: string; readonly repository: string } {
  const [first = '', ...rest] = name.split('/');

  if (rest.length > 0 && (first.includes('.') || first.includes(':') || first === 'localhost')) {
    return { host: first, repository: rest.join('/') };
  }

  // Docker Hub's names carry no host, and an official image's name no namespace
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

async function sendManifestHeadWithToken(
  url: string,
  challenge: string | null,
  githubToken: string | undefined,
): Promise<Response> {
  const token = await readPullToken(challenge, githubToken);

  return sendManifestHead(url, token);
}

async function readPullToken(
  challenge: string | null,
  githubToken: string | undefined,
): Promise<string> {
  const url = buildTokenURL(challenge ?? '');

  // ghcr.io's realm takes a GitHub token as the password of basic auth, with any user name
  const headers: Readonly<Record<string, string>> =
    githubToken !== undefined && url.protocol === 'https:' && url.host === 'ghcr.io'
      ? { authorization: `Basic ${btoa(`x:${githubToken}`)}` }
      : {};

  const response = await fetch(url, { headers, signal: AbortSignal.timeout(15_000) });

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

function parseChallenge(challenge: string): ReadonlyMap<string, string> {
  if (!/^bearer\s/iu.test(challenge)) {
    return new Map();
  }

  const parameters = new Map<string, string>();

  // Bearer realm="…",service="…",scope="…"
  for (const match of challenge.matchAll(/(?<key>\w+)="(?<value>[^"]*)"/gu)) {
    parameters.set(match.groups?.['key'] ?? '', match.groups?.['value'] ?? '');
  }

  return parameters;
}

function findToken(body: unknown): string | undefined {
  if (typeof body !== 'object' || body === null) {
    return undefined;
  }

  const fields: Readonly<Record<string, unknown>> = { ...body };

  // a token realm answers with token, access_token, or both
  const token = fields['token'] ?? fields['access_token'];

  return typeof token === 'string' && token !== '' ? token : undefined;
}
