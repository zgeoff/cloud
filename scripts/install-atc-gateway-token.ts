import { randomBytes } from 'node:crypto';
import type { ATCCredentialsPreflight } from './check-atc-credentials-preflight.ts';
import { ExitError } from './exit-error.ts';
import { findJSONField } from './find-json-field.ts';
import type { ATCCredentialsContext } from './load-atc-credentials-context.ts';
import { parseJSONOutput } from './parse-json-output.ts';
import { readHostScript } from './read-host-script.ts';
import { runOnHost } from './run-host-check.ts';
import { runOp } from './run-op.ts';

export async function installATCGatewayToken(
  context: Readonly<ATCCredentialsContext>,
  preflight: Readonly<ATCCredentialsPreflight>,
): Promise<void> {
  const file = `${context.directory}/gateway-token`;
  const hasFile = preflight.hostFiles.includes('gateway-token');

  context.printOut(
    `\n== 2/3 daemon bearer: 1Password ${context.vault}/${context.item} and root@${context.host}:${file}\n`,
  );

  if (preflight.hasItem && hasFile) {
    await requireMatchingCopies(context);

    context.printOut('skip: both exist and match\n');

    return;
  }

  if (preflight.hasItem || hasFile) {
    throw new ExitError(
      1,
      `only one copy exists (item: ${preflight.hasItem}, host file: ${hasFile}); fix by hand, then rerun`,
    );
  }

  await createGatewayToken(context);
}

function readItem(context: Readonly<ATCCredentialsContext>) {
  // op read prints the field and a newline, as the host file holds it
  return runOp(context, ['read', `op://${context.vault}/${context.item}/credential`]);
}

async function readHostSum(context: Readonly<ATCCredentialsContext>) {
  const line = await runOnHost(context, ['sha256sum', `${context.directory}/gateway-token`]);

  return line.split(' ')[0] ?? '';
}

async function requireMatchingCopies(context: Readonly<ATCCredentialsContext>) {
  const item = await readItem(context);
  const hostSum = await readHostSum(context);

  if (deriveSHA256(item) !== hostSum) {
    throw new ExitError(1, 'the 1Password item and the host file differ; fix by hand, then rerun');
  }
}

function deriveSHA256(value: string) {
  return new Bun.CryptoHasher('sha256').update(value).digest('hex');
}

async function createGatewayToken(context: Readonly<ATCCredentialsContext>) {
  const bearer = randomBytes(48).toString('base64url');

  await createItem(context, bearer);

  const script = await readHostScript('write-atc-gateway-token.sh');

  const stdin = Buffer.concat([script, Buffer.from(`${bearer}\n`)]);

  await runOnHost(context, ['bash', '-s', '--', context.directory], stdin);
  await requireCopiesOf(context, bearer);

  context.printOut('ok: the 1Password item and the host file match\n');
}

async function requireCopiesOf(context: Readonly<ATCCredentialsContext>, bearer: string) {
  const item = await readItem(context);
  const hostSum = await readHostSum(context);

  const localSum = deriveSHA256(`${bearer}\n`);

  if (localSum !== deriveSHA256(item) || localSum !== hostSum) {
    throw new ExitError(1, 'the copies differ; fix by hand before the gateway uses them');
  }
}

async function createItem(context: Readonly<ATCCredentialsContext>, bearer: string) {
  const template = {
    title: context.item,
    category: 'API_CREDENTIAL',
    fields: [{ id: 'credential', type: 'CONCEALED', label: 'credential', value: bearer }],
  };

  // the template goes on stdin, so the bearer never reaches op's argv
  const stdin = Buffer.from(JSON.stringify(template));

  const text = await runOp(
    context,
    ['item', 'create', '--vault', context.vault, '-', '--format', 'json'],
    stdin,
  );

  const item = parseJSONOutput(text, 'op item create');

  context.printOut(
    `1Password: ${String(findJSONField(item, 'title'))} (${String(findJSONField(item, 'id'))})\n`,
  );
}
