import { writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import type { StubAnswer, StubCall, StubHandler } from './build-stub-runner.ts';

// Stands in for the docker calls that the release bump makes, checked against buildx 0.37.1,
// docker 29.8.2 and nix 2.35.2 on 2026-10-13: an image's manifest descriptor, and the
// `nix flake lock` run, which writes the scenario's lock where the real lock writes it.
export interface StubReleaseDockerScenario {
  // the digest that each image reference names, as ghcr.io/zgeoff/<image>:<tag>
  readonly manifests?: Readonly<Record<string, string>>;

  // what the lock writes to <dir>/flake.lock, or the error it fails with instead
  readonly lock?: string;
  readonly lockError?: string;
}

export interface StubReleaseDocker {
  readonly handle: StubHandler;

  // the NIX_CONFIG that each lock run handed the container, in order; undefined for none
  readonly nixConfigs: readonly (string | undefined)[];
}

export function buildStubReleaseDocker(scenario: StubReleaseDockerScenario): StubReleaseDocker {
  const nixConfigs: (string | undefined)[] = [];

  return {
    handle: (call) =>
      call.argv[0] === 'docker'
        ? (buildInspectAnswer(scenario, call) ??
          runLock(scenario, call, (nixConfig) => {
            nixConfigs.push(nixConfig);
          }))
        : undefined,
    nixConfigs,
  };
}

function buildInspectAnswer(scenario: StubReleaseDockerScenario, call: StubCall) {
  const ref =
    /^docker buildx imagetools inspect (?<ref>\S+) --format \{\{json \.Manifest\}\}$/u.exec(
      call.argv.join(' '),
    )?.groups?.['ref'];

  const digest = scenario.manifests?.[ref ?? ''];

  if (ref === undefined) {
    return null;
  }

  return digest === undefined
    ? { exitCode: 1, stderr: `ERROR: ${ref}: not found\n` }
    : {
        stdout: `${JSON.stringify({ mediaType: 'application/vnd.oci.image.index.v1+json', digest, size: 1609 })}\n`,
      };
}

// docker hands the container the caller's NIX_CONFIG only with `-e NIX_CONFIG`, and sets no
// variable that the caller lacks
async function runLock(
  scenario: StubReleaseDockerScenario,
  call: StubCall,
  onNixConfig: (nixConfig: string | undefined) => void,
): Promise<StubAnswer | undefined> {
  const args = call.argv.slice(1);
  const mount = findLockMount(args);

  if (mount === undefined) {
    return undefined;
  }

  const nixConfig =
    args.includes('-e') && args[args.indexOf('-e') + 1] === 'NIX_CONFIG'
      ? call.options.env?.['NIX_CONFIG']
      : undefined;

  onNixConfig(nixConfig);

  if (scenario.lockError !== undefined) {
    return { exitCode: 1, stderr: `${scenario.lockError}\n` };
  }

  await writeFile(join(mount, 'flake.lock'), scenario.lock ?? '');

  return {};
}

// the directory a `nix flake lock` run mounts at /src, or undefined for any other run
function findLockMount(args: readonly string[]) {
  const mount = /^(?<dir>\/.+):\/src$/u.exec(args[3] ?? '')?.groups?.['dir'];

  const isLock =
    args[0] === 'run' &&
    args[1] === '--rm' &&
    args[2] === '-v' &&
    args.at(-2) === '-c' &&
    (args.at(-1) ?? '').includes('flake lock');

  return isLock ? mount : undefined;
}
