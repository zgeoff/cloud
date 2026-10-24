import { join } from 'node:path';
import invariant from 'tiny-invariant';

// the nixie image holds Bun but none of this repo's packages, so the Job runs one bundled file
export async function readSandboxImageScript(): Promise<string> {
  const output = await Bun.build({
    entrypoints: [join(import.meta.dir, 'run-sandbox-image-add.ts')],
    target: 'bun',
    minify: true,
  });

  const [artifact] = output.outputs;

  invariant(artifact, 'bun build gives one output for its one entry point');

  return artifact.text();
}
