import { appendFile, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import type { RegistryAnswer } from '../try-read-manifest-digest.ts';
import { tryReadManifestDigest } from '../try-read-manifest-digest.ts';
import type { GatewayPublishInput, PinnedImage } from './decide-gateway-publish.ts';
import { decideGatewayPublish } from './decide-gateway-publish.ts';

export interface RunDecideGatewayPublishOptions {
  readonly env: Readonly<Record<string, string | undefined>>;

  readonly cwd: string;
  readonly readText: (path: string) => Promise<string>;
  readonly appendText: (path: string, text: string) => Promise<void>;

  readonly readManifestDigest: (
    name: string,
    reference: string,
    githubToken: string | undefined,
  ) => Promise<RegistryAnswer>;

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

  await options.appendText(output, `publish=${String(decision.action === 'publish')}\n`);
  await options.appendText(summary, text);

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
const stackFile = 'infra/Pulumi.prod.yaml';

const pinnedTags = [
  { image: 'ghcr.io/zgeoff/atc-gateway', key: 'GATEWAY_IMAGE_TAG', stackField: 'image' },
  {
    image: 'ghcr.io/zgeoff/atc-gateway-backup',
    key: 'BACKUP_IMAGE_TAG',
    stackField: 'backupImage',
  },
] as const;

async function readPinnedImages(
  options: Readonly<RunDecideGatewayPublishOptions>,
): Promise<PinnedImage[] | Error> {
  const versions = await readRepoText(options, versionsFile);

  if (versions instanceof Error) {
    return versions;
  }

  const stack = await readRepoText(options, stackFile);

  if (stack instanceof Error) {
    return stack;
  }

  const unset = pinnedTags.find((pin) => findTag(versions, pin.key) === undefined);

  if (unset !== undefined) {
    return new Error(`${versionsFile} sets no ${unset.key}`);
  }

  const tags = pinnedTags.flatMap((pin) => {
    const tag = findTag(versions, pin.key);

    return tag === undefined ? [] : [{ image: pin.image, stackField: pin.stackField, tag }];
  });

  const config: unknown = Bun.YAML.parse(stack);
  const gateway = findMember(findMember(config, 'config'), 'geoff-cloud:atcGateway');
  const githubToken = options.env['GH_TOKEN'];

  return Promise.all(
    tags.map(async (pin) => {
      const reference = `${pin.image}:${pin.tag}`;
      const pinned = findMember(gateway, pin.stackField);

      const answer = await options.readManifestDigest(pin.image, pin.tag, githubToken);

      return {
        reference,
        answer,
        isPinnedInStack: typeof pinned === 'string' && pinned.startsWith(`${reference}@`),
      };
    }),
  );
}

async function readRepoText(
  options: Readonly<RunDecideGatewayPublishOptions>,
  file: string,
): Promise<string | Error> {
  try {
    return await options.readText(join(options.cwd, file));
  } catch (error) {
    return new Error(`cannot read ${file}: ${String(error)}`);
  }
}

function findTag(text: string, key: string): string | undefined {
  const line = text.split('\n').find((each) => each.startsWith(`${key}=`));
  const tag = line?.slice(key.length + 1).trim();

  return tag === '' ? undefined : tag;
}

function findMember(value: unknown, key: string): unknown {
  return typeof value === 'object' && value !== null && Object.hasOwn(value, key)
    ? Reflect.get(value, key)
    : undefined;
}

if (import.meta.main) {
  process.exitCode = await runDecideGatewayPublish({
    env: process.env,
    cwd: process.cwd(),
    readText: (path) => readFile(path, 'utf8'),
    appendText: (path, text) => appendFile(path, text),
    readManifestDigest: tryReadManifestDigest,
    printOut: (text) => {
      process.stdout.write(text);
    },
    printErr: (text) => {
      process.stderr.write(text);
    },
  });
}
