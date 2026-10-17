import { atcCloudGrantable as grantable } from './atc-cloud-grantable.ts';
import type { ATCCredentialsPreflight } from './check-atc-credentials-preflight.ts';
import { ExitError } from './exit-error.ts';
import { findJSONField } from './find-json-field.ts';
import { findRecord } from './find-record.ts';
import { buildHostImpArgv, formatImpCommand } from './imp-cli.ts';
import type { ATCCredentialsContext } from './load-atc-credentials-context.ts';
import { pickImpTokenVerdict } from './pick-imp-token-verdict.ts';
import { readHostScript } from './read-host-script.ts';
import { runHostCheck, runOnHost } from './run-host-check.ts';

// Mints impd's token atc-cloud (scope manage, imps harness-*, may grant atcCloudGrantable) on the
// host, straight into a root-only file there, so it never reaches this machine. impd shows a token
// once, so a rerun skips a token and file that match and stops at a lone one or a bad file.
export async function installATCImpToken(
  context: Readonly<ATCCredentialsContext>,
  preflight: Readonly<ATCCredentialsPreflight>,
): Promise<void> {
  const file = `${context.dir}/imp-token`;
  const token = findRecord(preflight.tokens, 'name', 'atc-cloud');
  const hasFile = preflight.hostFiles.includes('imp-token');

  context.printOut(
    `\n== 3/3 impd token atc-cloud (manage, harness-*, grantable ${grantable.join(',')}) to root@${context.host}:${file}\n`,
  );

  if (token !== undefined && hasFile) {
    await checkSavedToken(context, token, file);

    return;
  }

  if (token !== undefined || hasFile) {
    throw new ExitError(
      1,
      `only one exists (token: ${token !== undefined}, host file: ${hasFile}). impd shows a token once,\nso run '${formatImpCommand(['token', 'rm', 'atc-cloud'])}' in imp-host and remove ${file}, then rerun`,
    );
  }

  await createImpToken(context);
}

async function createImpToken(context: Readonly<ATCCredentialsContext>) {
  const script = await readHostScript('mint-atc-imp-token.sh');

  // the script runs imp's CLI with the argv that follows the directory
  await runOnHost(context, ['bash', '-s', '--', context.dir, ...buildHostImpArgv([])], script);
}

async function checkSavedToken(
  context: Readonly<ATCCredentialsContext>,
  token: unknown,
  file: string,
) {
  requireTokenLimits(token);

  await checkTokenFile(context, file);

  context.printOut(
    'skip: both exist, atc-cloud has the expected limits, and the file authenticates as it\n',
  );
}

function requireTokenLimits(token: unknown) {
  const tokenGrantable = findJSONField(token, 'grantable');

  // impd's order of the grantable list is its own, so the check compares the lists as sets
  const hasGrantable =
    Array.isArray(tokenGrantable) &&
    tokenGrantable.length === grantable.length &&
    grantable.every((secret) => tokenGrantable.includes(secret));

  const limits = [findJSONField(token, 'scope'), findJSONField(token, 'imps')];

  if (!hasGrantable || !Bun.deepEquals(limits, ['manage', ['harness-*']])) {
    throw new ExitError(
      1,
      `atc-cloud exists with another scope, imps or grantable list; fix it by hand, such as with\n'${formatImpCommand(['token', 'set', 'atc-cloud', '--grantable', grantable.join(',')])}' in imp-host, then rerun`,
    );
  }
}

// The metadata cannot show the file is right, so the host asks impd who the saved token is; only
// impd's answer returns. Anything short of a clear verdict leaves the file unchecked and changes
// nothing.
async function checkTokenFile(context: Readonly<ATCCredentialsContext>, file: string) {
  const script = await readHostScript('check-atc-imp-token.sh');

  // the script sets the two variables, and docker passes them into imp's CLI, off every argv
  const cli = buildHostImpArgv([], { env: ['IMP_TOKEN', 'IMP_URL'] });

  const result = await runHostCheck(
    context,
    ['bash', '-s', '--', context.dir, context.impdPort, ...cli],
    { stdin: script },
  );

  context.printErr(result.stderr.toString());

  const verdict = pickImpTokenVerdict({
    exitCode: result.exitCode,
    stdout: result.stdout.toString(),
  });

  if (verdict === 'bad') {
    throw new ExitError(
      1,
      `${file} does not authenticate to impd as the token atc-cloud (empty, more\nthan one line, stale or another token). impd shows a token once, so remove\n${file} and run '${formatImpCommand(['token', 'rm', 'atc-cloud'])}' in imp-host, then rerun to mint\na new one`,
    );
  }

  if (verdict !== 'good') {
    throw new ExitError(
      1,
      `${verdict}, so ${file} is unchecked; nothing changed.\n${pickFix(context, file, result.exitCode)}`,
    );
  }
}

function pickFix(context: Readonly<ATCCredentialsContext>, file: string, exitCode: number) {
  return exitCode === 120
    ? `Check ${file} on the host, then rerun`
    : `Check impd on the host's 127.0.0.1:${context.impdPort}, then rerun`;
}
