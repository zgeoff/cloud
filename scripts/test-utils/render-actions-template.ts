import { findJSONField } from '../find-json-field.ts';

// The contexts a step's env and run may read, as GitHub fills them for the run under test.
export interface ActionsTemplateContext {
  readonly github: object;
  readonly inputs: Readonly<Record<string, string>>;

  // the earlier steps' outputs, by step id
  readonly steps: Readonly<Record<string, { readonly outputs: Readonly<Record<string, string>> }>>;
}

const expression = /\$\{\{\s*(?<path>[^}]*?)\s*\}\}/gu;

// Renders a workflow value as the runner hands it to a step: a number or a boolean as its text, and
// each `${{ <path> }}` in a string as the path's value, empty when the path is missing, as on
// GitHub. Any other expression throws, so a test never runs a value the stand-in cannot render.
export function renderActionsTemplate(
  value: unknown,
  context: Readonly<ActionsTemplateContext>,
): string {
  if (typeof value === 'number' || typeof value === 'boolean') {
    return String(value);
  }

  if (typeof value !== 'string') {
    throw new TypeError(`unsupported workflow value: ${JSON.stringify(value)}`);
  }

  return value.replaceAll(expression, (_match: string, path: string) => resolvePath(path, context));
}

const contextPath = /^(?:github|inputs|steps)(?:\.[A-Za-z_][\w-]*)+$/u;

function resolvePath(path: string, context: Readonly<ActionsTemplateContext>): string {
  if (!contextPath.test(path)) {
    throw new Error(`unsupported expression: ${path}`);
  }

  const [root = '', ...keys] = path.split('.');
  const contexts: Readonly<Record<string, unknown>> = context;
  const found = keys.reduce<unknown>((current, key) => findJSONField(current, key), contexts[root]);

  if (found === undefined || found === null) {
    return '';
  }

  if (typeof found !== 'string' && typeof found !== 'number' && typeof found !== 'boolean') {
    throw new TypeError(`${path} is not a primitive`);
  }

  return String(found);
}
