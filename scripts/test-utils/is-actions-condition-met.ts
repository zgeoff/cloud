// Evaluates a job's `if` as GitHub's expression docs describe it: literals, `github` and `needs`
// paths, `!`, `==`, `!=`, `&&`, `||`, parentheses, and the status check functions. Anything else,
// such as another function or context, throws.
export interface ActionsNeed {
  readonly result: string;
  readonly outputs: Readonly<Record<string, string>>;
}

export interface ActionsConditionContext {
  readonly github: Readonly<Record<string, unknown>>;
  readonly needs: Readonly<Record<string, ActionsNeed>>;
}

const statusFunction = /\b(?:success|failure|cancelled|always)\(\)/u;

// A condition with no status check function implies `success()`: every need succeeded.
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
    const match = token.exec(expression)?.groups?.['token'];

    if (match === undefined) {
      throw new Error(`unsupported expression: ${expression}`);
    }

    tokens.push(match);
  }

  return tokens;
}

type Value = string | number | boolean | null;

// the parser's cursor moves as it reads, by design
interface Parser {
  readonly tokens: readonly string[];
  position: number;
  readonly context: Readonly<ActionsConditionContext>;
}

// GitHub's && and || return an operand, not a boolean
// oxlint-disable-next-line typescript/prefer-readonly-parameter-types
function parseOr(parser: Parser): Value {
  let value = parseAnd(parser);

  while (parser.tokens[parser.position] === '||') {
    parser.position += 1;

    const right = parseAnd(parser);

    value = isTruthy(value) ? value : right;
  }

  return value;
}

// oxlint-disable-next-line typescript/prefer-readonly-parameter-types
function parseAnd(parser: Parser): Value {
  let value = parseUnary(parser);

  while (parser.tokens[parser.position] === '&&') {
    parser.position += 1;

    const right = parseUnary(parser);

    value = isTruthy(value) ? right : value;
  }

  return value;
}

// oxlint-disable-next-line typescript/prefer-readonly-parameter-types
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

// oxlint-disable-next-line typescript/prefer-readonly-parameter-types
function parsePrimary(parser: Parser): Value {
  const current = parser.tokens[parser.position];

  parser.position += 1;

  if (current === '(') {
    return parseGroup(parser);
  }

  const call = parser.tokens.slice(parser.position, parser.position + 2).join('');

  if (current !== undefined && call === '()') {
    parser.position += 2;

    return resolveStatusFunction(current, parser.context);
  }

  return parseLiteralOrPath(current, parser.context);
}

// oxlint-disable-next-line typescript/prefer-readonly-parameter-types
function parseGroup(parser: Parser): Value {
  const value = parseOr(parser);

  requireToken(parser, ')');

  return value;
}

// oxlint-disable-next-line typescript/prefer-readonly-parameter-types
function requireToken(parser: Parser, expected: string): void {
  if (parser.tokens[parser.position] !== expected) {
    throw new Error(`expected ${expected}, found ${parser.tokens[parser.position] ?? 'the end'}`);
  }

  parser.position += 1;
}

function resolveStatusFunction(name: string, context: Readonly<ActionsConditionContext>): boolean {
  switch (name) {
    case 'success': {
      return isSuccess(context);
    }
    case 'failure': {
      return Object.values(context.needs).some((need) => need.result === 'failure');
    }
    case 'always': {
      return true;
    }

    // no test cancels a run
    case 'cancelled': {
      return false;
    }
    default: {
      throw new Error(`unsupported function: ${name}()`);
    }
  }
}

function isSuccess(context: Readonly<ActionsConditionContext>): boolean {
  return Object.values(context.needs).every((need) => need.result === 'success');
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
  };

  if (root === undefined || !(root in contexts)) {
    throw new Error(`unsupported context: ${path}`);
  }

  const value = keys.reduce<unknown>(
    (current, key) =>
      typeof current === 'object' && current !== null
        ? (current as Readonly<Record<string, unknown>>)[key]
        : undefined,
    contexts[root],
  );

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

function isTruthy(value: Value): boolean {
  return value !== false && value !== null && value !== 0 && value !== '' && !Number.isNaN(value);
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
