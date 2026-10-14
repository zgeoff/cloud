import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import type { RegistryAnswer } from './try-read-manifest-digest.ts';
import { tryReadManifestDigest } from './try-read-manifest-digest.ts';

// Asks each pin's registry about it, and prints each pin that fails: 0 when every pin holds, 1 on a
// failed pin, an unreadable pin file or a registry error. A release pin's tag must still name its
// digest; an upstream pin's digest must still be served, since upstream tags can move.
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
  const pins: Pin[] = [];

  for (const match of text.matchAll(pinPattern)) {
    pins.push({
      file,
      name: match.groups?.['name'] ?? '',
      tag: match.groups?.['tag'] ?? '',
      digest: match.groups?.['digest'] ?? '',
    });
  }

  return pins;
}

// The images this repo's release flows publish. A published release tag is never replaced, so a
// tag that names another digest is a hand edit that moved the tag or the digest alone.
const releasePrefix = 'ghcr.io/zgeoff/';

// What the check asks the registry for one pin. A release pin asks for its tag, whose digest must
// match. An upstream tag, such as Distroless's nonroot, moves when its publisher rebuilds the
// image, so an upstream pin asks only that the registry still serves its digest.
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

// one answer per distinct request, so a pin that several files hold costs one request
async function readRegistryDigests(
  pins: readonly Pin[],
): Promise<Readonly<Record<string, RegistryAnswer>>> {
  const distinct = new Map(
    pins.map((pin) => toManifestRequest(pin)).map((request) => [request.key, request]),
  );

  const answers = await Promise.all(
    [...distinct.values()].map(
      async (request) =>
        [request.key, await tryReadManifestDigest(request.name, request.reference)] as const,
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

// the pin's line when it fails, or undefined when it holds
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
    printOut: (text) => {
      process.stdout.write(text);
    },
    printErr: (text) => {
      process.stderr.write(text);
    },
  });
}
