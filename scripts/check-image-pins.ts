import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { missingGitHubTokenText, readGitHubToken } from './read-github-token.ts';
import type { Runner } from './run-process.ts';
import { runProcess } from './run-process.ts';
import type { RegistryAnswer } from './try-read-manifest-digest.ts';
import { tryReadManifestDigest } from './try-read-manifest-digest.ts';

export interface CheckImagePinsOptions {
  readonly args: readonly string[];
  readonly run: Runner;
  readonly printOut: (text: string) => void;
  readonly printErr: (text: string) => void;
}

const usage = 'usage: check-image-pins.ts [repo root]\n';

const pinFiles = [
  'infra/Pulumi.prod.yaml',
  'images/atc-gateway/versions.env',
  'images/atc-gateway/restore-job.yaml',
  'images/agent/Dockerfile',
  'deploy/nixie/restore-job.yaml',
  'nixos/hosts/geoffcloud/configuration.nix',
  'scripts/nix-image.sh',
  'infra/observability/test-nixie-alerts.sh',
];

export async function checkImagePins(options: Readonly<CheckImagePinsOptions>): Promise<number> {
  if (options.args.length > 1 || options.args[0]?.startsWith('-') === true) {
    options.printErr(usage);

    return 2;
  }

  const loaded = await loadPinsAndToken(options.args[0] ?? '.', options.run);

  if ('failures' in loaded) {
    options.printErr(loaded.failures.join(''));

    return 1;
  }

  const answers = await readRegistryDigests(loaded.pins, loaded.githubToken);

  return printReport(loaded.pins, answers, options);
}

async function loadPinsAndToken(
  root: string,
  run: Runner,
): Promise<
  | { readonly pins: readonly Pin[]; readonly githubToken: string | undefined }
  | { readonly failures: readonly string[] }
> {
  const loaded = await loadPins(root);

  if ('failures' in loaded || !loaded.pins.some((pin) => pin.name.startsWith('ghcr.io/'))) {
    return { ...loaded, githubToken: undefined };
  }

  // without the token a private package on ghcr.io would read as refused
  const githubToken = await readGitHubToken(run);

  return githubToken === undefined
    ? { failures: [`check-image-pins: ${missingGitHubTokenText}\n`] }
    : { pins: loaded.pins, githubToken };
}

interface Pin {
  readonly file: string;
  readonly name: string;
  readonly tag: string;
  readonly digest: string;
}

async function loadPins(
  root: string,
): Promise<{ readonly pins: readonly Pin[] } | { readonly failures: readonly string[] }> {
  const texts = await Promise.all(
    pinFiles.map((file) => readFile(join(root, file), 'utf8').catch(() => null)),
  );

  const unreadable = pinFiles.filter((_, index) => texts[index] === null);

  if (unreadable.length > 0) {
    return { failures: unreadable.map((file) => `check-image-pins: cannot read ${file}\n`) };
  }

  const parsed = pinFiles.map((file, index) => parsePins(file, texts[index] ?? ''));
  const malformed = parsed.flatMap((result) => result.malformed);

  return malformed.length > 0
    ? { failures: malformed }
    : { pins: parsed.flatMap((result) => result.pins) };
}

// a key such as GATEWAY_IMAGE_TAG names a tag alone, so only a key that ends in image matches
const referencePattern =
  /^\s*(?:from\s+(?:--platform=\S+\s+)?|(?:-\s+)?[\w-]*image\s*[:=]\s*)["']?(?<reference>[^\s"']+)/iu;

// an imp image lives in impd and no registry, so it has no digest to pin
const agentImagePattern = /^agent-[\da-f]{7,40}$/u;

// the anchors make a digest with an extra digit fail, where a substring match would hold
const pinPattern =
  /^(?<name>(?:[a-z\d][a-z\d.-]*(?::\d+)?\/)?[a-z\d][\w.-]*(?:\/[a-z\d][\w.-]*)*):(?<tag>\w[\w.-]{0,127})@(?<digest>sha256:[\da-f]{64})$/u;

function parsePins(
  file: string,
  text: string,
): { readonly pins: readonly Pin[]; readonly malformed: readonly string[] } {
  const parsed = text
    .split('\n')
    .map((line, index) => parseLine(`check-image-pins: ${file}:${index + 1}:`, file, line));

  return {
    pins: parsed.filter((result): result is Pin => typeof result === 'object'),
    malformed: parsed.filter((result): result is string => typeof result === 'string'),
  };
}

function parseLine(prefix: string, file: string, line: string): Pin | string | undefined {
  if (line.trimStart().startsWith('#')) {
    return undefined;
  }

  const reference = referencePattern.exec(line)?.groups?.['reference'];

  if (reference === undefined) {
    // a pin in another form fails rather than drop out of the check
    return line.includes('@sha256:')
      ? `${prefix} a digest outside an image reference: ${line.trim()}\n`
      : undefined;
  }

  if (agentImagePattern.test(reference)) {
    return undefined;
  }

  const match = pinPattern.exec(reference);

  if (match === null) {
    return reference.includes('@')
      ? `${prefix} ${reference} is not <name>:<tag>@sha256:<64 hex digits>\n`
      : `${prefix} ${reference} pins no digest\n`;
  }

  return {
    file,
    name: match.groups?.['name'] ?? '',
    tag: match.groups?.['tag'] ?? '',
    digest: match.groups?.['digest'] ?? '',
  };
}

// The images this repo's release flows publish. A published release tag is never replaced, so a
// tag that names another digest is a hand edit that moved the tag or the digest alone.
const releasePrefix = 'ghcr.io/zgeoff/';

// An upstream tag, such as Distroless's nonroot, moves when its publisher rebuilds the image, so
// an upstream pin asks only that the registry still serves its digest.
interface ManifestRequest {
  readonly key: string;
  readonly name: string;
  readonly reference: string;
  readonly release: boolean;
}

function toManifestRequest(pin: Pin): ManifestRequest {
  const release = pin.name.startsWith(releasePrefix);

  return release
    ? { key: `${pin.name}:${pin.tag}`, name: pin.name, reference: pin.tag, release }
    : { key: `${pin.name}@${pin.digest}`, name: pin.name, reference: pin.digest, release };
}

async function readRegistryDigests(
  pins: readonly Pin[],
  githubToken: string | undefined,
): Promise<Readonly<Record<string, RegistryAnswer>>> {
  const distinct = new Map(
    pins.map((pin) => toManifestRequest(pin)).map((request) => [request.key, request]),
  );

  const answers = await Promise.all(
    [...distinct.values()].map(
      async (request) =>
        [
          request.key,
          await tryReadManifestDigest(request.name, request.reference, githubToken),
        ] as const,
    ),
  );

  return Object.fromEntries(answers);
}

function printReport(
  pins: readonly Pin[],
  answers: Readonly<Record<string, RegistryAnswer>>,
  options: Readonly<CheckImagePinsOptions>,
): number {
  const findings = pins.flatMap((pin) => {
    const request = toManifestRequest(pin);
    const answer = answers[request.key];
    const finding = answer === undefined ? undefined : findFinding(pin, request, answer);

    return finding === undefined ? [] : [finding];
  });

  if (findings.length > 0) {
    options.printErr(findings.join(''));

    return 1;
  }

  const releases = Object.keys(answers).filter((key) => key.startsWith(releasePrefix)).length;

  options.printOut(
    `check-image-pins: ${pins.length} pins hold: ${releases} release tags name their pinned digests, and ${Object.keys(answers).length - releases} upstream digests are still served\n`,
  );

  return 0;
}

function findFinding(
  pin: Pin,
  request: ManifestRequest,
  answer: RegistryAnswer,
): string | undefined {
  const prefix = `check-image-pins: ${pin.file}: ${pin.name}:${pin.tag}`;

  if ('error' in answer) {
    return `${prefix}: cannot read ${request.name}${request.release ? ':' : '@'}${request.reference}: ${answer.error}\n`;
  }

  if ('missing' in answer) {
    return request.release
      ? `${prefix}: the registry has no tag ${pin.tag}\n`
      : `${prefix} pins ${pin.digest}, which the registry no longer serves\n`;
  }

  return !request.release || answer.digest === pin.digest
    ? undefined
    : `${prefix} pins ${pin.digest}, but the registry's ${pin.tag} is ${answer.digest}\n`;
}

if (import.meta.main) {
  process.exitCode = await checkImagePins({
    args: process.argv.slice(2),
    run: runProcess,
    printOut: (text) => {
      process.stdout.write(text);
    },
    printErr: (text) => {
      process.stderr.write(text);
    },
  });
}
