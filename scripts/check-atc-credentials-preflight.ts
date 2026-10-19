import { atcCloudGrantable } from './atc-cloud-grantable.ts';
import { ExitError } from './exit-error.ts';
import { findJSONField } from './find-json-field.ts';
import { findRecord } from './find-record.ts';
import { formatImpCommand, loadHostImpJSON } from './imp-cli.ts';
import type { ATCCredentialsContext } from './load-atc-credentials-context.ts';
import { parseJSONOutput } from './parse-json-output.ts';
import { runOnHost } from './run-host-check.ts';
import { runOp } from './run-op.ts';

export interface ATCCredentialsPreflight {
  // impd's secrets and tokens, as imp's CLI prints them
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

  const secrets = await loadHostImpJSON(context, ['secret', 'ls']);

  requireGrantableSecrets(secrets);

  const tokens = await loadHostImpJSON(context, ['token', 'ls']);
  const hasItem = await hasDaemonTokenItem(context);
  const hostFiles = await readHostFiles(context);

  context.printOut(
    `ok: 1Password vault ${context.vault}, atc-key, ssh root@${context.host}, impd grantableTokens, ${context.directory}\n`,
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

// a failing `info` stops here with docker's own message, so the check reads only a real answer
async function requireGrantableTokens(context: Readonly<ATCCredentialsContext>) {
  const info = await loadHostImpJSON(context, ['info']);

  const features = findJSONField(info, 'features');

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
      `impd lacks ${missing.join(', ')}, which atc-cloud may grant; add each with\n'${formatImpCommand(['secret', 'add'])}' in imp-host, then rerun. Nothing changed`,
    );
  }
}

async function hasDaemonTokenItem(context: Readonly<ATCCredentialsContext>) {
  const text = await runOp(context, ['item', 'list', '--vault', context.vault, '--format', 'json']);

  const items = parseJSONOutput(text, 'op item list');

  return findRecord(items, 'title', context.item) !== undefined;
}

async function readHostFiles(context: Readonly<ATCCredentialsContext>) {
  // the directory is a bind mount of tank/cloud; with it gone, a credential would land in the
  // clear on the root disk and the bind would hide it later. bash gets the directory as $1, so
  // the line itself holds no path to quote.
  await runOnHost(context, [
    'bash',
    '-c',
    'mountpoint -q "$1" || { echo "$1 is not a mount point; nothing written" >&2; exit 1; }; install -d -m 0700 -o root -g root "$1"',
    'bash',
    context.directory,
  ]);

  const listing = await runOnHost(context, ['ls', context.directory]);

  return listing.split('\n').filter((line) => line !== '');
}
