import { readFile } from 'node:fs/promises';
import { join } from 'node:path';

// Asks each pin's registry for the digest its tag names, and prints each pin whose digest differs:
// 0 when every tag agrees, 1 on a mismatch, an unreadable pin file or a registry error. A published
// tag is never replaced, so a mismatch is a hand edit that moved a tag or a digest alone.
export interface CheckImagePinsOptions {
  readonly args: readonly string[];
  readonly printOut: (text: string) => void;
  readonly printErr: (text: string) => void;
}

const usage = 'usage: check-image-pins.ts [repo root]\n';

// every file that pins an image by tag and digest
const pinFiles = [
  'infra/Pulumi.prod.yaml',
  'images/atc-gateway/versions.env',
  'images/atc-gateway/restore-job.yaml',
  'images/agent/Dockerfile',
  'deploy/nixie/restore-job.yaml',
  'nixos/hosts/geoffcloud/configuration.nix',
  'scripts/nix-image.sh',
];

export async function checkImagePins(options: Readonly<CheckImagePinsOptions>): Promise<number> {
  if (options.args.length > 1 || options.args[0]?.startsWith('-') === true) {
    options.printErr(usage);

    return 2;
  }

  const loaded = await loadPins(options.args[0] ?? '.');

  if ('unreadable' in loaded) {
    options.printErr(
      loaded.unreadable.map((file) => `check-image-pins: cannot read ${file}\n`).join(''),
    );

    return 1;
  }

  const answers = await readRegistryDigests(loaded.pins);

  return printReport(loaded.pins, answers, options);
}

// one pin as a file writes it: the image's name, its tag and the digest it pins
interface Pin {
  readonly file: string;
  readonly name: string;
  readonly tag: string;
  readonly digest: string;
}

// <name>:<tag>@sha256:<digest>, where the name may start with a registry host and port
const pinPattern =
  /(?<name>(?:[a-z\d][a-z\d.-]*(?::\d+)?\/)?[a-z\d][\w.-]*(?:\/[a-z\d][\w.-]*)*):(?<tag>\w[\w.-]{0,127})@(?<digest>sha256:[\da-f]{64})/gu;

// every pin the files hold, or the files it cannot read
async function loadPins(
  root: string,
): Promise<{ readonly pins: readonly Pin[] } | { readonly unreadable: readonly string[] }> {
  const texts = await Promise.all(
    pinFiles.map((file) => readFile(join(root, file), 'utf8').catch(() => null)),
  );

  const unreadable = pinFiles.filter((_, index) => texts[index] === null);

  return unreadable.length > 0
    ? { unreadable }
    : { pins: pinFiles.flatMap((file, index) => collectPins(file, texts[index] ?? '')) };
}

function collectPins(file: string, text: string): readonly Pin[] {
  return [...text.matchAll(pinPattern)].map((match) => ({
    file,
    name: match.groups?.['name'] ?? '',
    tag: match.groups?.['tag'] ?? '',
    digest: match.groups?.['digest'] ?? '',
  }));
}

// the registry's answer for one name and tag: the digest it names, or why it gave none
type RegistryAnswer = { readonly digest: string } | { readonly error: string };

// one answer per distinct name and tag, so a pin that several files hold costs one request
async function readRegistryDigests(
  pins: readonly Pin[],
): Promise<ReadonlyMap<string, RegistryAnswer>> {
  const distinct = new Map(pins.map((pin) => [`${pin.name}:${pin.tag}`, pin]));

  const answers = await Promise.all(
    [...distinct].map(
      async ([reference, pin]) => [reference, await tryReadTagDigest(pin.name, pin.tag)] as const,
    ),
  );

  return new Map(answers);
}

async function tryReadTagDigest(name: string, tag: string): Promise<RegistryAnswer> {
  try {
    return await readTagDigest(name, tag);
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
async function readTagDigest(name: string, tag: string): Promise<RegistryAnswer> {
  const location = resolveRegistry(name);
  const url = `https://${location.host}/v2/${location.repository}/manifests/${tag}`;

  const first = await sendManifestHead(url, undefined);

  const response =
    first.status === 401
      ? await sendManifestHeadWithToken(url, first.headers.get('www-authenticate'))
      : first;

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

  return new Map(
    [...challenge.matchAll(/(?<key>\w+)="(?<value>[^"]*)"/gu)].map((match) => [
      match.groups?.['key'] ?? '',
      match.groups?.['value'] ?? '',
    ]),
  );
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

function printReport(
  pins: readonly Pin[],
  answers: ReadonlyMap<string, RegistryAnswer>,
  options: Readonly<CheckImagePinsOptions>,
): number {
  const findings = pins.flatMap((pin) => {
    const answer = answers.get(`${pin.name}:${pin.tag}`);
    const finding = answer === undefined ? undefined : findFinding(pin, answer);

    return finding === undefined ? [] : [finding];
  });

  if (findings.length > 0) {
    options.printErr(findings.join(''));

    return 1;
  }

  options.printOut(
    `check-image-pins: ${pins.length} pins of ${answers.size} tags agree with their registries\n`,
  );

  return 0;
}

// the pin's line when its tag disagrees or does not resolve, or undefined when it agrees
function findFinding(pin: Pin, answer: RegistryAnswer): string | undefined {
  const reference = `${pin.name}:${pin.tag}`;

  if ('error' in answer) {
    return `check-image-pins: ${pin.file}: cannot read ${reference}'s digest: ${answer.error}\n`;
  }

  return answer.digest === pin.digest
    ? undefined
    : `check-image-pins: ${pin.file}: ${reference} pins ${pin.digest}, but the registry's ${pin.tag} is ${answer.digest}\n`;
}

if (import.meta.main) {
  process.exitCode = await checkImagePins({
    args: process.argv.slice(2),
    printOut: (text) => {
      process.stdout.write(text);
    },
    printErr: (text) => {
      process.stderr.write(text);
    },
  });
}
