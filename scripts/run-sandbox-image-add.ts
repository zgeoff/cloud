import { createImpClient } from '@impz/client';
import { buildImageAddPlan } from './build-image-add-plan.ts';
import type { HeldImage } from './build-image-add-plan.ts';
import { parseNixieSandboxManifest } from './parse-nixie-sandbox-manifest.ts';
import type { SandboxImage } from './parse-nixie-sandbox-manifest.ts';
import { runProcess } from './run-process.ts';
import type { Runner } from './run-process.ts';

export interface SandboxImageAddOptions {
  readonly env: Readonly<Record<string, string | undefined>>;
  readonly run: Runner;
  readonly printOut: (text: string) => void;
  readonly printErr: (text: string) => void;
}

export async function runSandboxImageAdd(
  options: Readonly<SandboxImageAddOptions>,
): Promise<number> {
  const impdURL = options.env['IMPD_URL'];
  const secretsFile = options.env['NIXIE_SECRETS_FILE'];

  if (impdURL === undefined || secretsFile === undefined) {
    options.printErr('run-sandbox-image-add: IMPD_URL and NIXIE_SECRETS_FILE must be set\n');

    return 2;
  }

  const token = await readImpdToken(options, secretsFile);

  const manifest = token === undefined ? undefined : await readManifest(options);

  if (token === undefined || manifest === undefined) {
    return 1;
  }

  const client = createImpClient({ url: impdURL, token });

  const heldImages = await readHeldImages(options, () => client.images.list());

  if (heldImages === undefined) {
    return 1;
  }

  const plan = buildImageAddPlan(manifest, heldImages);

  if (plan.conflicts.length > 0) {
    options.printErr(plan.conflicts.map((conflict) => `${conflict}\n`).join(''));

    return 1;
  }

  for (const name of plan.held) {
    options.printOut(`held ${name}\n`);
  }

  return runAdds(options, plan.adds, (image) => client.images.add(image));
}

async function readImpdToken(
  options: Readonly<SandboxImageAddOptions>,
  secretsFile: string,
): Promise<string | undefined> {
  const result = await options.run(['sops', 'decrypt', '--extract', '["impd_token"]', secretsFile]);

  const token = result.stdout.toString().trim();

  if (result.exitCode !== 0 || token === '') {
    options.printErr(
      `run-sandbox-image-add: sops could not read impd_token (exit ${result.exitCode}): ${result.stderr.toString()}`,
    );

    return undefined;
  }

  return token;
}

async function readManifest(
  options: Readonly<SandboxImageAddOptions>,
): Promise<readonly SandboxImage[] | undefined> {
  const result = await options.run(['nixie', 'sandbox-manifest']);

  if (result.exitCode !== 0) {
    options.printErr(
      `run-sandbox-image-add: nixie sandbox-manifest exited ${result.exitCode}: ${result.stderr.toString()}`,
    );

    return undefined;
  }

  const manifest = parseNixieSandboxManifest(result.stdout.toString());

  if (!manifest.ok) {
    options.printErr(`run-sandbox-image-add: ${manifest.error}\n`);

    return undefined;
  }

  return manifest.images;
}

async function readHeldImages(
  options: Readonly<SandboxImageAddOptions>,
  listImages: () => Promise<readonly HeldImage[]>,
): Promise<readonly HeldImage[] | undefined> {
  try {
    return await listImages();
  } catch (error) {
    options.printErr(
      `run-sandbox-image-add: impd did not list its images: ${formatError(error)}\n`,
    );

    return undefined;
  }
}

function formatError(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

interface ImageAddInput {
  readonly ref: string;
  readonly name: string;
}

async function runAdds(
  options: Readonly<SandboxImageAddOptions>,
  adds: readonly SandboxImage[],
  addImage: (image: ImageAddInput) => Promise<unknown>,
): Promise<number> {
  // impd pulls one image at a time, as nixie's own start does
  for (const image of adds) {
    try {
      await addImage({ ref: image.ref, name: image.name });
    } catch (error) {
      options.printErr(
        `run-sandbox-image-add: impd did not add the image ${image.name} from ${image.ref}: ${formatError(error)}\n`,
      );

      return 1;
    }

    options.printOut(`added ${image.name}\n`);
  }

  return 0;
}

if (import.meta.main) {
  process.exitCode = await runSandboxImageAdd({
    env: process.env,
    run: runProcess,
    printOut: (text) => {
      process.stdout.write(text);
    },
    printErr: (text) => {
      process.stderr.write(text);
    },
  });
}
