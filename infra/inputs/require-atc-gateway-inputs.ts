import type { z } from 'zod';
import { atcGatewayConfigSchema } from './atc-gateway-config-schema.ts';
import { requireVariable } from './require-variable.ts';
import { toATCGatewayTokenVariable } from './to-atc-gateway-token-variable.ts';
import type { ATCGatewayConfig, Environment } from './types.ts';

interface CheckedGatewayInputs {
  readonly config: ATCGatewayConfig;

  readonly tokens: Readonly<Record<string, string>>;
}

export function requireATCGatewayInputs(raw: unknown, env: Environment): CheckedGatewayInputs {
  const result = atcGatewayConfigSchema.safeParse(raw);

  if (!result.success) {
    throw new Error(result.error.issues.map((issue) => formatIssue(issue)).join('\n'));
  }

  return {
    config: result.data,
    tokens: Object.fromEntries(
      Object.keys(result.data.daemons).map((name) => [
        name,
        requireToken(toATCGatewayTokenVariable(name), env),
      ]),
    ),
  };
}

function formatIssue(issue: z.core.$ZodIssue): string {
  return `${['atcGateway', ...issue.path.map(String)].join('.')} ${issue.message}`;
}

// atc's daemon takes a token of at least 32 bytes
const minTokenBytes = 32;

function requireToken(variable: string, env: Environment): string {
  const token = requireVariable(env, variable, ".env must reference the daemon's token");

  if (/\s/u.test(token)) {
    throw new Error(`${variable} must be the one token, with no whitespace`);
  }

  if (Buffer.byteLength(token) < minTokenBytes) {
    throw new Error(`${variable} is shorter than ${minTokenBytes} bytes`);
  }

  return token;
}
