import { parseJSONOutput } from './parse-json-output.ts';
import type { HostIO } from './run-host-check.ts';
import { runOnHost } from './run-host-check.ts';
import type { ScriptIO } from './run-or-exit.ts';
import { runOrExit } from './run-or-exit.ts';

// imp's CLI, named here once: every script runs it through this module, so a rename of the binary
// is a change to this line. A call whose output a script reads asks for --json; the commands that
// print no JSON (rm, image rm, cp, exec) run through the argv builders.
export const impCLI = 'impz';

// the argv of one call to the CLI on this machine
export function buildImpArgv(args: readonly string[]): readonly string[] {
  return [impCLI, ...args];
}

// the argv of one call to the CLI in imp-host. docker passes stdin on only with -i, which a call
// that reads none leaves out, since a host script's text can sit on that stdin. Each env name
// passes docker's own value through, so a secret in it never enters the argv.
export function buildHostImpArgv(
  args: readonly string[],
  options: { readonly stdin?: boolean; readonly env?: readonly string[] } = {},
): readonly string[] {
  const input = options.stdin === true ? ['-i'] : [];
  const env = (options.env ?? []).flatMap((name) => ['-e', name]);

  return ['docker', 'exec', ...input, ...env, 'imp-host', impCLI, ...args];
}

// a call as a person types it, for a message that says what to run
export function formatImpCommand(args: readonly string[]): string {
  return buildImpArgv(args).join(' ');
}

// Runs one call on this machine with --json and parses its answer; a failed call or an answer
// that is not JSON stops the script
export async function loadImpJSON(
  io: Readonly<ScriptIO>,
  args: readonly string[],
): Promise<unknown> {
  const result = await runOrExit(io, buildImpArgv([...args, '--json']));

  return parseJSONOutput(result.stdout.toString(), formatImpCommand(args));
}

// Runs one call in the host's imp-host container with --json and parses its answer. A stopped
// container fails the run with docker's own message; stdin, when given, reaches the CLI.
export async function loadHostImpJSON(
  io: Readonly<HostIO>,
  args: readonly string[],
  stdin?: Buffer,
): Promise<unknown> {
  const argv = buildHostImpArgv([...args, '--json'], { stdin: stdin !== undefined });

  const text = await runOnHost(io, argv, stdin);

  return parseJSONOutput(text, formatImpCommand(args));
}
