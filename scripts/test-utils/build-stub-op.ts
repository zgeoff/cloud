// the vaults are mutable state by design
/* oxlint-disable typescript/prefer-readonly-parameter-types */
import { findJSONField } from '../find-json-field.ts';
import type { StubAnswer, StubCall, StubHandler } from './build-stub-runner.ts';

// Stands in for the 1Password CLI, op 2.40.0 as images/agent/Dockerfile pins it, at the calls
// install-atc-gateway-credentials makes. A vault maps each item's title to its credential. op's
// exit codes and error frames come from community reports; the docs leave them open.
export interface StubOpScenario {
  // each vault's items, by title, with their credentials
  readonly vaults: Record<string, Record<string, string>>;
  readonly failAt?: 'item-list' | 'item-create';

  // what `op read` prints in place of the saved credential
  readonly readValue?: string;
}

export interface StubOp {
  readonly handle: StubHandler;

  // the scenario's vaults, as the calls left them
  readonly vaults: Readonly<Record<string, Readonly<Record<string, string>>>>;

  // the service account token of each call, in order
  readonly tokensSeen: readonly (string | undefined)[];
}

export function buildStubOp(scenario: StubOpScenario): StubOp {
  const tokensSeen: (string | undefined)[] = [];

  return {
    handle: (call) => {
      const isOp = call.argv[0] === 'op';

      if (isOp) {
        tokensSeen.push(call.options.env?.['OP_SERVICE_ACCOUNT_TOKEN']);
      }

      return isOp ? buildOpAnswer(scenario, call) : undefined;
    },
    vaults: scenario.vaults,
    tokensSeen,
  };
}

type OpAnswer = (scenario: StubOpScenario, call: StubCall, args: readonly string[]) => StubAnswer;

// the command shapes from www.1password.dev/cli/reference (vault get, item list, item create
// reading the item JSON on stdin, and read), checked on 2026-10-08
const commands: readonly (readonly [RegExp, OpAnswer])[] = [
  [
    /^vault get (?<vault>\S+) --format json$/u,
    (scenario, _call, args) => buildVaultAnswer(scenario, args),
  ],
  [
    /^item list --vault (?<vault>\S+) --format json$/u,
    (scenario, _call, args) => buildListAnswer(scenario, args),
  ],
  [
    /^item create --vault (?<vault>\S+) - --format json$/u,
    (scenario, call, args) => createItem(scenario, call, args),
  ],
  [
    /^read op:\/\/(?<vault>[^/]+)\/(?<item>[^/]+)\/credential$/u,
    (scenario, _call, args) => buildReadAnswer(scenario, args),
  ],
];

function buildOpAnswer(scenario: StubOpScenario, call: StubCall) {
  const line = call.argv.slice(1).join(' ');
  const command = commands.find(([pattern]) => pattern.test(line));
  const match = command?.[0].exec(line);

  return command === undefined || match === null || match === undefined
    ? undefined
    : command[1](scenario, call, match.slice(1));
}

function buildNoVaultError(vault: string) {
  return {
    exitCode: 1,
    stderr: `[ERROR] 2026/10/07 12:00:00 "${vault}" isn't a vault in this account. Specify the vault with its ID or name.\n`,
  };
}

// the rate-limit text from www.1password.dev/service-accounts/rate-limits/
const rateLimitError =
  "[ERROR] 2026/10/07 12:00:00 (429) Too Many Requests: You've reached the maximum number of this type of requests this service account is allowed to make. Please retry in 59 minutes or try other requests.\n";

function buildVaultAnswer(scenario: StubOpScenario, args: readonly string[]) {
  const vault = args[0] ?? '';

  if (scenario.vaults[vault] === undefined) {
    return buildNoVaultError(vault);
  }

  return { stdout: `${JSON.stringify({ id: 'fixture-vault-id', name: vault })}\n` };
}

// the item JSON of www.1password.dev/cli/item-template-json/, without the timestamps
function buildItem(vault: string, title: string) {
  return {
    id: 'fixture-item-id',
    title,
    version: 1,
    vault: { id: 'fixture-vault-id', name: vault },
    category: 'API_CREDENTIAL',
  };
}

function buildListAnswer(scenario: StubOpScenario, args: readonly string[]) {
  const vault = args[0] ?? '';
  const items = scenario.vaults[vault];

  if (scenario.failAt === 'item-list') {
    return { exitCode: 1, stderr: rateLimitError };
  }

  if (items === undefined) {
    return buildNoVaultError(vault);
  }

  const listed = Object.keys(items).map((title) => buildItem(vault, title));

  return { stdout: `${JSON.stringify(listed, null, 2)}\n` };
}

function createItem(scenario: StubOpScenario, call: StubCall, args: readonly string[]) {
  const vault = args[0] ?? '';
  const items = scenario.vaults[vault];

  if (scenario.failAt === 'item-create') {
    return { exitCode: 1, stderr: rateLimitError };
  }

  if (items === undefined) {
    return buildNoVaultError(vault);
  }

  const template = parseItemTemplate(call.stdin);

  items[template.title] = template.credential;

  return { stdout: `${JSON.stringify(buildItem(vault, template.title), null, 2)}\n` };
}

// the item template the script sends on stdin: its title, and the value of its credential field
function parseItemTemplate(text: string) {
  const template: unknown = JSON.parse(text);
  const title = findJSONField(template, 'title');
  const fields = findJSONField(template, 'fields');

  const field: unknown = Array.isArray(fields)
    ? fields.find((entry) => findJSONField(entry, 'id') === 'credential')
    : undefined;

  const value = findJSONField(field, 'value');

  return {
    title: typeof title === 'string' ? title : '',
    credential: typeof value === 'string' ? value : '',
  };
}

// op read prints a newline after the secret unless -n is given
function buildReadAnswer(scenario: StubOpScenario, args: readonly string[]) {
  const [vault = '', item = ''] = args;
  const credential = scenario.readValue ?? scenario.vaults[vault]?.[item];

  if (credential === undefined) {
    return {
      exitCode: 1,
      stderr: `[ERROR] 2026/10/07 12:00:00 could not read secret op://${vault}/${item}/credential: could not get item ${vault}/${item}: "${item}" isn't an item in the "${vault}" vault.\n`,
    };
  }

  return { stdout: `${credential}\n` };
}
