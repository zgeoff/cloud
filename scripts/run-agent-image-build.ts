import { mkdir } from 'node:fs/promises';
import { join } from 'node:path';
import { ExitError } from './exit-error.ts';
import { findJSONField } from './find-json-field.ts';
import { findRecord } from './find-record.ts';
import { buildImpArgv, formatImpCommand, loadImpJSON } from './imp-cli.ts';
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
  readonly source: string;
  readonly digest: string;
}

// Builds the image from a git archive of the commit, so the clone's working tree never reaches it.
// imp's image build prints no progress off a terminal, so the build runs quietly.
export async function runAgentImageBuild(
  io: Readonly<ScriptIO>,
  build: Readonly<AgentImageBuild>,
): Promise<BuiltAgentImage> {
  const source = await createImageSource(io, build);

  await runImpBuild(io, build, source);

  const images = await loadImpJSON(io, ['image', 'ls']);

  const digest = findJSONField(findRecord(images, 'name', build.image), 'digest');

  return { source, digest: typeof digest === 'string' ? digest : '' };
}

// git archive writes a tar of the commit's image and scripts, which tar extracts into src
async function createImageSource(io: Readonly<ScriptIO>, build: Readonly<AgentImageBuild>) {
  const source = join(build.work, 'src');
  const tarball = join(build.work, 'src.tar');
  const archive = ['git', 'archive', '--output', tarball, build.sha, 'images/agent', 'scripts'];

  await mkdir(source);
  await runOrExit(io, archive, { cwd: build.cwd });
  await runOrExit(io, ['tar', '-xf', tarball, '-C', source]);

  return source;
}

// impd can still finish a build that outlives the timeout, so the message says to read imp image
// ls before a retry
async function runImpBuild(
  io: Readonly<ScriptIO>,
  build: Readonly<AgentImageBuild>,
  source: string,
) {
  const command = formatImpCommand(['image', 'build']);

  io.printErr(
    `building ${build.image} from ${build.sha}; ${command} shows no progress off a terminal\n`,
  );

  const argv = buildImpArgv([
    'image',
    'build',
    join(source, 'images/agent'),
    '--name',
    build.image,
  ]);

  const result = await io.run(argv, { timeoutMs: build.timeoutMs });

  const output = `${result.stdout.toString()}${result.stderr.toString()}`;

  if (output !== '') {
    io.printErr(output);
  }

  if (result.timedOut) {
    throw new ExitError(
      1,
      `${command} did not finish within ${build.timeout}; impd may still finish ${build.image}, so read ${formatImpCommand(['image', 'ls'])} before a retry`,
    );
  }

  if (result.exitCode !== 0) {
    throw new ExitError(1, `${command} failed for ${build.image}`);
  }
}
