import { buildBunPinCheck } from '@zgeoff/cloud-preview/build-bun-pin-check.ts';
import { bunRelease } from '@zgeoff/cloud-preview/bun-release.ts';
import { contractScript } from '@zgeoff/cloud-preview/contract-script.ts';

export interface BunRelease {
  readonly version: string;
  readonly url: string;
  readonly sha256: string;
}

export interface CheckPreviewBunOptions {
  readonly release: BunRelease;
  readonly script: string;
  readonly printErr: (text: string) => void;
}

export async function checkPreviewBun(options: Readonly<CheckPreviewBunOptions>): Promise<number> {
  const failures = [
    ...collectScriptFailures(options.release, options.script),
    ...(await readTarballFailures(options.release)),
  ];

  if (failures.length === 0) {
    return 0;
  }

  options.printErr(failures.join(''));

  return 1;
}

function collectScriptFailures(release: BunRelease, script: string): string[] {
  const steps = [
    {
      name: `the download of ${release.url}`,
      text: `curl -fsSL -o /opt/bun/bun.tgz ${release.url}\n`,
    },
    {
      name: `the check of its sha256 ${release.sha256}`,
      text: `echo "${release.sha256}  /opt/bun/bun.tgz" | sha256sum -c -`,
    },
    {
      name: `the check of the repository's pin against Bun ${release.version}`,
      text: buildBunPinCheck(release.version),
    },
    { name: 'the install', text: 'bun install --frozen-lockfile\n' },
  ];

  let from = 0;
  let previous: string | null = null;

  for (const step of steps) {
    const at = script.indexOf(step.text, from);

    if (at === -1) {
      const after = previous === null ? '' : ` after ${previous}`;

      return [`check-preview-bun: the contract script lacks ${step.name}${after}\n`];
    }

    from = at + step.text.length;
    previous = step.name;
  }

  return [];
}

async function readTarballFailures(release: BunRelease): Promise<string[]> {
  try {
    const response = await fetch(release.url);

    if (!response.ok) {
      return [`check-preview-bun: cannot download ${release.url}: HTTP ${response.status}\n`];
    }

    const tarball = await response.arrayBuffer();

    const sha256 = new Bun.CryptoHasher('sha256').update(tarball).digest('hex');

    return sha256 === release.sha256
      ? []
      : [
          `check-preview-bun: ${release.url} has sha256 ${sha256}, but packages/preview/bun-release.ts pins ${release.sha256}\n`,
        ];
  } catch (error) {
    const reason = error instanceof Error ? error.message : String(error);

    return [`check-preview-bun: cannot download ${release.url}: ${reason}\n`];
  }
}

if (import.meta.main) {
  process.exitCode = await checkPreviewBun({
    release: bunRelease,
    script: contractScript,
    printErr: (text) => {
      process.stderr.write(text);
    },
  });
}
