import { match } from 'ts-pattern';
import { findJSONField } from '../find-json-field.ts';

// Evaluates a job's or a step's `if` as GitHub's expression docs describe it: literals, `github`,
// `needs` and `steps` paths, `!`, `==`, `!=`, `&&`, `||`, parentheses, and the status check
// functions. Anything else, such as another function or context, throws.
interface ActionsNeed {
  readonly result: string;
  readonly outputs: Readonly<Record<string, string>>;
}

// a step's outcome before continue-on-error, and its conclusion after it
interface ActionsStep {
  readonly outcome: string;
  readonly conclusion: string;
  readonly outputs: Readonly<Record<string, string>>;
}

export interface ActionsConditionContext {
  readonly github: object;
  readonly needs: Readonly<Record<string, ActionsNeed>>;

  // the earlier steps of the job, by id, for a step's `if`; their conclusions decide success() and
  // failure() beside the needs, and without them a `steps` path throws
  readonly steps?: Readonly<Record<string, ActionsStep>>;
}

const statusFunction = /\b(?:success|failure|cancelled|always)\(\)/u;

// the parser's cursor moves as it reads, by design
interface Parser {
  readonly tokens: readonly string[];
  position: number;
  readonly context: Readonly<ActionsConditionContext>;
}

// A condition with no status check function implies `success()`: every need and earlier step
// succeeded.
export function isActionsConditionMet(
  condition: string,
  context: Readonly<ActionsConditionContext>,
): boolean {
  const expression = condition.trim().replace(/^\$\{\{(?<body>.*)\}\}$/su, '$<body>');
  const parser: Parser = { tokens: splitTokens(expression), position: 0, context };
  const met = isTruthy(parseOr(parser));

  if (parser.position !== parser.tokens.length) {
    throw new Error(`unexpected ${parser.tokens[parser.position]} in: ${expression}`);
  }

  return statusFunction.test(expression) ? met : met && isSuccess(context);
}

const token = /\s*(?<token>\|\||&&|==|!=|!|\(|\)|'(?:[^']|'')*'|[A-Za-z_][\w.-]*)/uy;

function splitTokens(expression: string): string[] {
  const tokens: string[] = [];

  token.lastIndex = 0;

  while (expression.slice(token.lastIndex).trim() !== '') {
    const found = token.exec(expression)?.groups?.['token'];

    if (found === undefined) {
      throw new Error(`unsupported expression: ${expression}`);
    }

    tokens.push(found);
  }

  return tokens;
}

type Value = string | number | boolean | null;

function isTruthy(value: Value): boolean {
  return value !== false && value !== null && value !== 0 && value !== '' && !Number.isNaN(value);
}

// GitHub's && and || return an operand, not a boolean
function parseOr(parser: Parser): Value {
  let value = parseAnd(parser);

  while (parser.tokens[parser.position] === '||') {
    parser.position += 1;

    const right = parseAnd(parser);

    value = isTruthy(value) ? value : right;
  }

  return value;
}

function parseAnd(parser: Parser): Value {
  let value = parseUnary(parser);

  while (parser.tokens[parser.position] === '&&') {
    parser.position += 1;

    const right = parseUnary(parser);

    value = isTruthy(value) ? right : value;
  }

  return value;
}

function parseUnary(parser: Parser): Value {
  if (parser.tokens[parser.position] === '!') {
    parser.position += 1;

    return !isTruthy(parseUnary(parser));
  }

  const left = parsePrimary(parser);
  const operator = parser.tokens[parser.position];

  if (operator !== '==' && operator !== '!=') {
    return left;
  }

  parser.position += 1;

  const equal = isLooselyEqual(left, parsePrimary(parser));

  return operator === '==' ? equal : !equal;
}

function parsePrimary(parser: Parser): Value {
  const current = parser.tokens[parser.position];

  parser.position += 1;

  if (current === '(') {
    return parseGroup(parser);
  }

  const call = parser.tokens.slice(parser.position, parser.position + 2).join('');

  if (current !== undefined && call === '()') {
    parser.position += 2;

    return isStatusFunctionMet(current, parser.context);
  }

  return parseLiteralOrPath(current, parser.context);
}

function parseGroup(parser: Parser): Value {
  const value = parseOr(parser);

  requireToken(parser, ')');

  return value;
}

function requireToken(parser: Parser, expected: string): void {
  if (parser.tokens[parser.position] !== expected) {
    throw new Error(`expected ${expected}, found ${parser.tokens[parser.position] ?? 'the end'}`);
  }

  parser.position += 1;
}

function isStatusFunctionMet(name: string, context: Readonly<ActionsConditionContext>): boolean {
  // no test cancels a run, so cancelled() is always false
  return match(name)
    .with('success', () => isSuccess(context))
    .with('failure', () => isFailure(context))
    .with('always', () => true)
    .with('cancelled', () => false)
    .otherwise(() => {
      throw new Error(`unsupported function: ${name}()`);
    });
}

function isSuccess(context: Readonly<ActionsConditionContext>): boolean {
  return (
    Object.values(context.needs).every((need) => need.result === 'success') &&
    Object.values(context.steps ?? {}).every((step) => step.conclusion !== 'failure')
  );
}

function isFailure(context: Readonly<ActionsConditionContext>): boolean {
  return (
    Object.values(context.needs).some((need) => need.result === 'failure') ||
    Object.values(context.steps ?? {}).some((step) => step.conclusion === 'failure')
  );
}

function parseLiteralOrPath(
  current: string | undefined,
  context: Readonly<ActionsConditionContext>,
): Value {
  if (current?.startsWith("'") === true) {
    return current.slice(1, -1).replaceAll("''", "'");
  }

  if (current === 'true' || current === 'false') {
    return current === 'true';
  }

  if (current === undefined || !/^[A-Za-z_]/u.test(current)) {
    throw new Error(`unexpected ${current ?? 'end of expression'}`);
  }

  return resolvePath(current, context);
}

// a missing property reads as null, as in GitHub's expressions
function resolvePath(path: string, context: Readonly<ActionsConditionContext>): Value {
  const [root, ...keys] = path.split('.');

  const contexts: Readonly<Record<string, unknown>> = {
    github: context.github,
    needs: context.needs,
    ...(context.steps === undefined ? {} : { steps: context.steps }),
  };

  if (root === undefined || !(root in contexts)) {
    throw new Error(`unsupported context: ${path}`);
  }

  const value = keys.reduce<unknown>((current, key) => findJSONField(current, key), contexts[root]);

  return toValue(value ?? null, path);
}

function toValue(value: unknown, path: string): Value {
  if (
    typeof value === 'string' ||
    typeof value === 'number' ||
    typeof value === 'boolean' ||
    value === null
  ) {
    return value;
  }

  throw new Error(`${path} is not a primitive`);
}

// GitHub's loose equality: strings compare case-insensitively, other mixed types as numbers
function isLooselyEqual(left: Value, right: Value): boolean {
  if (typeof left === 'string' && typeof right === 'string') {
    return left.toLowerCase() === right.toLowerCase();
  }

  if (typeof left === typeof right) {
    return left === right;
  }

  return toNumber(left) === toNumber(right);
}

function toNumber(value: Value): number {
  if (value === null) {
    return 0;
  }

  if (typeof value === 'string') {
    return value.trim() === '' ? 0 : Number(value);
  }

  return Number(value);
}
