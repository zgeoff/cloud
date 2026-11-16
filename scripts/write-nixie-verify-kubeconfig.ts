import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createNixieVerifyKubeconfig } from './nixie-verify/create-nixie-verify-kubeconfig.ts';
import type { Runner } from './run-process.ts';
import { runProcess } from './run-process.ts';

export interface WriteNixieVerifyKubeconfigOptions {
  readonly run: Runner;

  // an empty folder that only this user reads, for the admin kubeconfig while kubectl runs
  readonly workDir: string;
  readonly printOut: (text: string) => void;
  readonly printErr: (text: string) => void;
}

const adminReference = 'op://cloud/k3s-kubeconfig/kubeconfig.yaml';
const vault = 'nixie';
const item = 'nixie-prod-kubeconfig';
const fileName = 'kubeconfig.yaml';

// 90 days, as a Go duration: kubectl reads no day unit
const tokenDuration = '2160h';

// Writes a kubeconfig for the nixie-verify service account, whose token lasts 90 days, to the nixie
// vault, where an agent's prod check of nixie reads it. Only the token's expiry is printed.
export async function writeNixieVerifyKubeconfig(
  options: Readonly<WriteNixieVerifyKubeconfigOptions>,
): Promise<number> {
  const admin = await options.run(['op', 'read', '--no-newline', adminReference], {
    timeoutMs: 60_000,
  });

  if (admin.exitCode !== 0) {
    return fail(options, `could not read ${adminReference}: ${admin.stderr.toString().trim()}`);
  }

  const adminKubeconfig = join(options.workDir, 'admin-kubeconfig.yaml');

  await writeFile(adminKubeconfig, admin.stdout, { mode: 0o600 });

  const minted = await createNixieVerifyKubeconfig(options.run, {
    adminKubeconfig,
    duration: tokenDuration,
  });

  await rm(adminKubeconfig, { force: true });

  if (!minted.ok) {
    return fail(options, minted.error);
  }

  const stored = await writeKubeconfigItem(options.run, minted.text);

  if (stored !== null) {
    return fail(options, stored);
  }

  options.printOut(
    `stored op://${vault}/${item}/${fileName}; its nixie-verify token expires at ${minted.expiresAt}\n`,
  );

  return 0;
}

function fail(options: Readonly<WriteNixieVerifyKubeconfigOptions>, message: string): number {
  options.printErr(`write-nixie-verify-kubeconfig: ${message}\n`);

  return 1;
}

// op document create adds a second item of the same title, so an item that exists gets an edit
async function writeKubeconfigItem(run: Runner, text: string): Promise<string | null> {
  const found = await run(['op', 'item', 'get', item, '--vault', vault, '--format', 'json'], {
    timeoutMs: 60_000,
  });

  const foundText = found.stderr.toString();

  if (found.exitCode !== 0 && !foundText.includes(`"${item}" isn't an item`)) {
    return `could not read the item ${item} in vault ${vault}: ${foundText.trim()}`;
  }

  const argv =
    found.exitCode === 0
      ? ['op', 'document', 'edit', item, '--vault', vault, '--file-name', fileName, '-']
      : [
          'op',
          'document',
          'create',
          '--vault',
          vault,
          '--title',
          item,
          '--file-name',
          fileName,
          '-',
        ];

  const written = await run(argv, { stdin: Buffer.from(text), timeoutMs: 60_000 });

  return written.exitCode === 0
    ? null
    : `could not store ${item} in vault ${vault}: ${written.stderr.toString().trim()}`;
}

if (import.meta.main) {
  const workDir = await mkdtemp(join(tmpdir(), 'write-nixie-verify-kubeconfig-'));

  process.exitCode = await writeNixieVerifyKubeconfig({
    run: runProcess,
    workDir,
    printOut: (text) => {
      process.stdout.write(text);
    },
    printErr: (text) => {
      process.stderr.write(text);
    },
  });

  await rm(workDir, { recursive: true, force: true });
}
