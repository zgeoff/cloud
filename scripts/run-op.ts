import type { ATCCredentialsContext } from './load-atc-credentials-context.ts';
import { runOrExit } from './run-or-exit.ts';

export async function runOp(
  context: Readonly<ATCCredentialsContext>,
  args: readonly string[],
  stdin?: Buffer,
): Promise<string> {
  // the service account token goes in the environment, never the argv
  const options = stdin === undefined ? { env: context.opEnv } : { env: context.opEnv, stdin };

  const result = await runOrExit(context, ['op', ...args], options);

  return result.stdout.toString();
}
