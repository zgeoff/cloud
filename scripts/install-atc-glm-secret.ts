import type { ATCCredentialsPreflight } from './check-atc-credentials-preflight.ts';
import { ExitError } from './exit-error.ts';
import { findJSONField } from './find-json-field.ts';
import { findRecord } from './find-record.ts';
import { loadHostImpJSON } from './imp-cli.ts';
import type { ATCCredentialsContext } from './load-atc-credentials-context.ts';
import { runOrExit } from './run-or-exit.ts';

const glmAddArgs = [
  'secret',
  'add',
  'glm',

  // imp 5 takes custom as the older name of static, and stores and lists static
  '--kind',
  'custom',
  '--hosts',
  'api.z.ai',
  '--header',
  'authorization',
  '--scheme',
  'bearer',
];

export async function installATCGLMSecret(
  context: Readonly<ATCCredentialsContext>,
  preflight: Readonly<ATCCredentialsPreflight>,
): Promise<void> {
  context.printOut('\n== 1/3 impd secret glm (api.z.ai, authorization: Bearer)\n');

  const glm = findRecord(preflight.secrets, 'name', 'glm');

  if (glm !== undefined) {
    requireGLMRules(glm);

    context.printOut('skip: glm exists with the expected rules\n');

    return;
  }

  const key = await readZAIKey(context);
  const added = await loadHostImpJSON(context, glmAddArgs, Buffer.from(`${key}\n`));

  printSecret(context, added);
}

const glmRules = [{ host: 'api.z.ai', header: 'authorization', scheme: 'bearer' }];

function requireGLMRules(glm: unknown) {
  if (
    findJSONField(glm, 'kind') !== 'static' ||
    !Bun.deepEquals(findJSONField(glm, 'rules'), glmRules)
  ) {
    throw new ExitError(1, 'glm exists with other rules; fix it by hand, then rerun');
  }
}

async function readZAIKey(context: Readonly<ATCCredentialsContext>) {
  const result = await runOrExit(context, ['atc-key', 'zai']);

  // trailing newlines go, as a command substitution drops them
  const key = result.stdout.toString().replace(/\n+$/u, '');

  if (key === '') {
    throw new ExitError(1, 'atc-key zai printed nothing; nothing changed');
  }

  return key;
}

function printSecret(context: Readonly<ATCCredentialsContext>, secret: unknown) {
  const summary = {
    name: findJSONField(secret, 'name'),
    kind: findJSONField(secret, 'kind'),
    rules: findJSONField(secret, 'rules'),
  };

  context.printOut(`${JSON.stringify(summary)}
`);
}
