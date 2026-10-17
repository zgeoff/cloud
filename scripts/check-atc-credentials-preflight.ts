import { atcCloudGrantable } from './atc-cloud-grantable.ts';
import { ExitError } from './exit-error.ts';
import { findJSONField } from './find-json-field.ts';
import { findRecord } from './find-record.ts';
import type { ATCCredentialsContext } from './load-atc-credentials-context.ts';
import { parseJSONOutput } from './parse-json-output.ts';
import { readImpList } from './read-imp-list.ts';
import { runOnHost } from './run-on-host.ts';
import { runOp } from './run-op.ts';
import { toShellArg } from './to-shell-arg.ts';

export interface ATCCredentialsPreflight {
  // impd's secrets and tokens, as the impz CLI prints them
  readonly secrets: unknown;
  readonly tokens: unknown;
  readonly hasItem: boolean;
  readonly hostFiles: readonly string[];
}

// Reads what exists, and creates only the root-only directory on the host, so every check that
// can stop the run comes before the first change
export async function checkATCCredentialsPreflight(
  context: Readonly<ATCCredentialsContext>,
): Promise<ATCCredentialsPreflight> {
  context.printOut('\n== preflight\n');

  await requireTools(context);
  await requireGrantableTokens(context);

  const secrets = await readImpList(context, 'secret');

  requireGrantableSecrets(secrets);

  const tokens = await readImpList(context, 'token');
  const hasItem = await hasDaemonTokenItem(context);
  const hostFiles = await readHostFiles(context);

  context.printOut(
    `ok: 1Password vault ${context.vault}, atc-key, ssh ${context.host}, impd grantableTokens, ${context.dir}\n`,
  );

  return { secrets, tokens, hasItem, hostFiles };
}

// the vault, atc-key and the host; command -v finds atc-key as bash does, and atc-key itself runs
// only once glm is missing
async function requireTools(context: Readonly<ATCCredentialsContext>) {
  await runOp(context, ['vault', 'get', context.vault, '--format', 'json']);

  const found = await context.run(['sh', '-c', 'command -v atc-key > /dev/null']);

  if (found.exitCode !== 0) {
    throw new ExitError(1, 'atc-key is not on PATH; nothing changed');
  }

  await runOnHost(context, ['true']);
}

// a failing `impz info` stops here with docker's own message, so the check reads only a real answer
async function requireGrantableTokens(context: Readonly<ATCCredentialsContext>) {
  const text = await runOnHost(context, ['docker', 'exec', 'imp-host', 'impz', 'info', '--json']);

  const features = findJSONField(parseJSONOutput(text, 'impz info'), 'features');

  if (findJSONField(features, 'grantableTokens') !== true) {
    throw new ExitError(1, 'impd lacks grantableTokens; nothing changed');
  }
}

// impd refuses to mint atc-cloud while a secret it may grant is missing, so every one must exist
// before the run writes a credential. glm is the exception: the run adds it itself.
function requireGrantableSecrets(secrets: unknown) {
  const missing = atcCloudGrantable.filter(
    (name) => name !== 'glm' && findRecord(secrets, 'name', name) === undefined,
  );

  if (missing.length > 0) {
    throw new ExitError(
      1,
      `impd lacks ${missing.join(', ')}, which atc-cloud may grant; add each with\n'impz secret add' in imp-host, then rerun. Nothing changed`,
    );
  }
}

async function hasDaemonTokenItem(context: Readonly<ATCCredentialsContext>) {
  const text = await runOp(context, ['item', 'list', '--vault', context.vault, '--format', 'json']);

  const items = parseJSONOutput(text, 'op item list');

  return findRecord(items, 'title', context.item) !== undefined;
}

async function readHostFiles(context: Readonly<ATCCredentialsContext>) {
  const dir = toShellArg(context.dir);

  // the directory is a bind mount of tank/cloud; with it gone, a credential would land in the
  // clear on the root disk and the bind would hide it later
  const refusal = toShellArg(`${context.dir} is not a mount point; nothing written`);

  await runOnHost(context, [
    `mountpoint -q ${dir} || { echo ${refusal} >&2; exit 1; }; install -d -m 0700 -o root -g root ${dir}`,
  ]);

  const listing = await runOnHost(context, [`ls ${dir}`]);

  return listing.split('\n').filter((line) => line !== '');
}
