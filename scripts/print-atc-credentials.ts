import { findJSONField } from './find-json-field.ts';
import { findRecord } from './find-record.ts';
import { loadHostImpJSON } from './imp-cli.ts';
import type { ATCCredentialsContext } from './load-atc-credentials-context.ts';
import { runOnHost } from './run-host-check.ts';

// Prints what impd and the host now hold: names, limits and modes, never a value. A file that is
// gone fails the run with stat's message.
export async function printATCCredentials(context: Readonly<ATCCredentialsContext>): Promise<void> {
  context.printOut('\n== check\n');

  const secrets = await loadHostImpJSON(context, ['secret', 'ls']);
  const tokens = await loadHostImpJSON(context, ['token', 'ls']);

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
  const paths = [
    context.directory,
    `${context.directory}/gateway-token`,
    `${context.directory}/imp-token`,
  ];

  const stat = await runOnHost(context, ['stat', '-c', '%n %U %a %s bytes', ...paths]);

  context.printOut(stat);
}

function buildSummary(record: unknown, keys: readonly string[]) {
  return Object.fromEntries(keys.map((key) => [key, findJSONField(record, key)]));
}
