import { findJSONField } from './find-json-field.ts';
import { findRecord } from './find-record.ts';
import type { ATCCredentialsContext } from './load-atc-credentials-context.ts';
import { readImpList } from './read-imp-list.ts';
import { runOnHost } from './run-on-host.ts';
import { toShellArg } from './to-shell-arg.ts';

// Prints what impd and the host now hold: names, limits and modes, never a value. A file that is
// gone fails the run with stat's message.
export async function printATCCredentials(context: Readonly<ATCCredentialsContext>): Promise<void> {
  context.printOut('\n== check\n');

  const secrets = await readImpList(context, 'secret');
  const tokens = await readImpList(context, 'token');

  const glm = findRecord(secrets, 'name', 'glm');
  const token = findRecord(tokens, 'name', 'atc-cloud');

  if (glm !== undefined) {
    context.printOut(`${JSON.stringify(buildSummary(glm, ['name', 'kind', 'rules', 'imps']))}\n`);
  }

  if (token !== undefined) {
    context.printOut(
      `${JSON.stringify(buildSummary(token, ['name', 'scope', 'imps', 'grantable']))}\n`,
    );
  }

  await printModes(context);
}

async function printModes(context: Readonly<ATCCredentialsContext>) {
  const paths = [context.dir, `${context.dir}/gateway-token`, `${context.dir}/imp-token`];

  const stat = await runOnHost(context, [
    `stat -c '%n %U %a %s bytes' ${paths.map((path) => toShellArg(path)).join(' ')}`,
  ]);

  context.printOut(stat);
}

function buildSummary(record: unknown, keys: readonly string[]) {
  return Object.fromEntries(keys.map((key) => [key, findJSONField(record, key)]));
}
