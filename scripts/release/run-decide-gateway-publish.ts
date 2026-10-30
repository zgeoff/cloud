import { appendFile, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tryReadManifestDigest } from '../try-read-manifest-digest.ts';
import type { GatewayPublishInput, PinnedImage } from './decide-gateway-publish.ts';
import { decideGatewayPublish } from './decide-gateway-publish.ts';

export interface RunDecideGatewayPublishOptions {
  readonly env: Readonly<Record<string, string | undefined>>;

  readonly cwd: string;
  readonly printOut: (text: string) => void;
  readonly printErr: (text: string) => void;
}

export async function runDecideGatewayPublish(
  options: Readonly<RunDecideGatewayPublishOptions>,
): Promise<number> {
  const env = options.env;
  const output = env['GITHUB_OUTPUT'] ?? '';
  const summary = env['GITHUB_STEP_SUMMARY'] ?? '';

  const missing = ['EVENT', 'REF', 'GITHUB_OUTPUT', 'GITHUB_STEP_SUMMARY'].find(
    (name) => (env[name] ?? '') === '',
  );

  if (missing !== undefined) {
    options.printErr(`${missing} must be set, as the workflow sets it\n`);

    return 2;
  }

  const input = await readInput(options);

  if (input instanceof Error) {
    options.printErr(`${input.message}\n`);

    return 1;
  }

  const decision = decideGatewayPublish(input);
  const text = `${decision.action}: ${decision.reason}\n`;

  if (decision.action === 'unknown') {
    options.printErr(text);

    return 1;
  }

  await appendFile(output, `publish=${String(decision.action === 'publish')}\n`);
  await appendFile(summary, text);

  options.printOut(text);

  return 0;
}

async function readInput(
  options: Readonly<RunDecideGatewayPublishOptions>,
): Promise<GatewayPublishInput | Error> {
  const env = options.env;
  const eventName = env['EVENT'] ?? '';
  const pinnedImages = eventName === 'push' ? await readPinnedImages(options) : [];

  return pinnedImages instanceof Error
    ? pinnedImages
    : { eventName, ref: env['REF'] ?? '', pushInput: env['PUSH_INPUT'] ?? '', pinnedImages };
}

const versionsFile = 'images/atc-gateway/versions.env';

const pinnedTags = [
  { image: 'ghcr.io/zgeoff/atc-gateway', key: 'GATEWAY_IMAGE_TAG' },
  { image: 'ghcr.io/zgeoff/atc-gateway-backup', key: 'BACKUP_IMAGE_TAG' },
] as const;

async function readPinnedImages(
  options: Readonly<RunDecideGatewayPublishOptions>,
): Promise<PinnedImage[] | Error> {
  const text = await readFile(join(options.cwd, versionsFile), 'utf8').catch(
    (error: unknown) => new Error(`cannot read ${versionsFile}: ${String(error)}`),
  );

  if (text instanceof Error) {
    return text;
  }

  const unset = pinnedTags.find((pin) => findTag(text, pin.key) === undefined);

  if (unset !== undefined) {
    return new Error(`${versionsFile} sets no ${unset.key}`);
  }

  const tags = pinnedTags.flatMap((pin) => {
    const tag = findTag(text, pin.key);

    return tag === undefined ? [] : [{ image: pin.image, tag }];
  });

  const githubToken = options.env['GH_TOKEN'];

  return Promise.all(
    tags.map(async (pin) => ({
      reference: `${pin.image}:${pin.tag}`,
      answer: await tryReadManifestDigest(pin.image, pin.tag, githubToken),
    })),
  );
}

function findTag(text: string, key: string): string | undefined {
  const line = text.split('\n').find((each) => each.startsWith(`${key}=`));
  const tag = line?.slice(key.length + 1).trim();

  return tag === '' ? undefined : tag;
}

if (import.meta.main) {
  process.exitCode = await runDecideGatewayPublish({
    env: process.env,
    cwd: process.cwd(),
    printOut: (text) => {
      process.stdout.write(text);
    },
    printErr: (text) => {
      process.stderr.write(text);
    },
  });
}
