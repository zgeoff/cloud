import type { ATCCredentialsContext } from './load-atc-credentials-context.ts';
import { runOrExit } from './run-or-exit.ts';

// Runs the 1Password CLI with the service account token in its environment, never its argv
export async function runOp(
  context: Readonly<ATCCredentialsContext>,
  args: readonly string[],
  stdin?: Buffer,
): Promise<string> {
  const options = stdin === undefined ? { env: context.opEnv } : { env: context.opEnv, stdin };

  const result = await runOrExit(context, ['op', ...args], options);

  return result.stdout.toString();
}
