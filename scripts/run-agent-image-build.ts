import { mkdir } from 'node:fs/promises';
import { join } from 'node:path';
import { ExitError } from './exit-error.ts';
import { findJSONField } from './find-json-field.ts';
import { findRecord } from './find-record.ts';
import { readImpJSON } from './read-imp-json.ts';
import type { ScriptIO } from './run-or-exit.ts';
import { runOrExit } from './run-or-exit.ts';

export interface AgentImageBuild {
  readonly image: string;
  readonly sha: string;

  // the clone that git archives the commit from
  readonly cwd: string;

  // a directory the caller owns and removes
  readonly work: string;

  // the timeout as given, for the message, and in milliseconds
  readonly timeout: string;
  readonly timeoutMs: number;
}

export interface BuiltAgentImage {
  // the commit's extracted image and scripts
  readonly src: string;
  readonly digest: string;
}

// Builds the image from a git archive of the commit, so the clone's working tree never reaches it.
// imp image build prints no progress off a terminal, so the build runs quietly.
export async function runAgentImageBuild(
  io: Readonly<ScriptIO>,
  build: Readonly<AgentImageBuild>,
): Promise<BuiltAgentImage> {
  const src = await createImageSource(io, build);

  await runImpBuild(io, build, src);

  const images = await readImpJSON(io, ['image', 'ls', '--json']);

  const digest = findJSONField(findRecord(images, 'name', build.image), 'digest');

  return { src, digest: typeof digest === 'string' ? digest : '' };
}

// git archive writes a tar of the commit's image and scripts, which tar extracts into src
async function createImageSource(io: Readonly<ScriptIO>, build: Readonly<AgentImageBuild>) {
  const src = join(build.work, 'src');
  const tarball = join(build.work, 'src.tar');
  const archive = ['git', 'archive', '--output', tarball, build.sha, 'images/agent', 'scripts'];

  await mkdir(src);
  await runOrExit(io, archive, { cwd: build.cwd });
  await runOrExit(io, ['tar', '-xf', tarball, '-C', src]);

  return src;
}

// impd can still finish a build that outlives the timeout, so the message says to read imp image
// ls before a retry
async function runImpBuild(io: Readonly<ScriptIO>, build: Readonly<AgentImageBuild>, src: string) {
  io.printErr(
    `building ${build.image} from ${build.sha}; imp image build shows no progress off a terminal\n`,
  );

  const argv = ['imp', 'image', 'build', join(src, 'images/agent'), '--name', build.image];

  const result = await io.run(argv, { timeoutMs: build.timeoutMs });

  const output = `${result.stdout.toString()}${result.stderr.toString()}`;

  if (output !== '') {
    io.printErr(output);
  }

  if (result.timedOut) {
    throw new ExitError(
      1,
      `imp image build did not finish within ${build.timeout}; impd may still finish ${build.image}, so read imp image ls before a retry`,
    );
  }

  if (result.exitCode !== 0) {
    throw new ExitError(1, `imp image build failed for ${build.image}`);
  }
}
