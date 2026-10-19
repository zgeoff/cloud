import { parseJSONOutput } from './parse-json-output.ts';
import type { HostIO } from './run-host-check.ts';
import { runOnHost } from './run-host-check.ts';
import type { ScriptIO } from './run-or-exit.ts';
import { runOrExit } from './run-or-exit.ts';

export const impCLI = 'impz';

export function buildImpArgv(args: readonly string[]): readonly string[] {
  return [impCLI, ...args];
}

export function buildHostImpArgv(
  args: readonly string[],
  options: { readonly stdin?: boolean; readonly env?: readonly string[] } = {},
): readonly string[] {
  // docker passes stdin on only with -i, and a host script's text can sit on that stdin
  const input = options.stdin === true ? ['-i'] : [];

  // each env name passes docker's own value through, so a secret never enters the argv
  const env = (options.env ?? []).flatMap((name) => ['-e', name]);

  return ['docker', 'exec', ...input, ...env, 'imp-host', impCLI, ...args];
}

export function formatImpCommand(args: readonly string[]): string {
  return buildImpArgv(args).join(' ');
}

export async function loadImpJSON(
  io: Readonly<ScriptIO>,
  args: readonly string[],
): Promise<unknown> {
  const result = await runOrExit(io, buildImpArgv([...args, '--json']));

  return parseJSONOutput(result.stdout.toString(), formatImpCommand(args));
}

export async function loadHostImpJSON(
  io: Readonly<HostIO>,
  args: readonly string[],
  stdin?: Buffer,
): Promise<unknown> {
  const argv = buildHostImpArgv([...args, '--json'], { stdin: stdin !== undefined });

  const text = await runOnHost(io, argv, stdin);

  return parseJSONOutput(text, formatImpCommand(args));
}
