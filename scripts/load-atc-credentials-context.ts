import { readFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { topology } from '@zgeoff/cloud-topology';
import { ExitError } from './exit-error.ts';
import { findJSONField } from './find-json-field.ts';
import { parseJSONOutput } from './parse-json-output.ts';
import type { HostIO } from './run-on-host.ts';
import type { ScriptIO } from './run-or-exit.ts';

export interface ATCCredentialsContext extends HostIO {
  readonly vault: string;
  readonly item: string;
  readonly dir: string;
  readonly impdPort: string;

  // op's environment, which carries the 1Password service account token
  readonly opEnv: Readonly<Record<string, string | undefined>>;
}

export interface ATCCredentialsOptions extends ScriptIO {
  readonly env: Readonly<Record<string, string | undefined>>;
}

// Reads the settings install-atc-gateway-credentials takes from its environment, each with the
// production default
export async function loadATCCredentialsContext(
  options: Readonly<ATCCredentialsOptions>,
): Promise<ATCCredentialsContext> {
  const opToken = await readOpToken(options.env);

  return {
    run: options.run,
    printOut: options.printOut,
    printErr: options.printErr,
    host: options.env['ATC_CREDENTIALS_HOST'] ?? 'root@geoffcloud',
    vault: options.env['ATC_CREDENTIALS_VAULT'] ?? 'cloud',
    item: options.env['ATC_DAEMON_TOKEN_ITEM'] ?? 'atc-daemon-token',
    dir: options.env['ATC_CREDENTIALS_DIR'] ?? '/var/lib/atc-daemon-secrets',
    impdPort: options.env['ATC_IMPD_PORT'] ?? String(topology.imp.apiPort),
    opEnv: { ...options.env, OP_SERVICE_ACCOUNT_TOKEN: opToken },
  };
}

// The environment's token, or the one the cloud checkout's Claude Code settings file holds
async function readOpToken(env: Readonly<Record<string, string | undefined>>) {
  const fromEnv = env['OP_SERVICE_ACCOUNT_TOKEN'] ?? '';

  if (fromEnv !== '') {
    return fromEnv;
  }

  const home = env['HOME'] ?? homedir();
  const path = env['CLOUD_OP_SETTINGS'] ?? join(home, 'projects/cloud/.claude/settings.local.json');

  const text = await readSettings(path);

  const token = findJSONField(
    findJSONField(parseJSONOutput(text, path), 'env'),
    'OP_SERVICE_ACCOUNT_TOKEN',
  );

  if (typeof token !== 'string' || token === '') {
    throw new ExitError(1, `${path} holds no env.OP_SERVICE_ACCOUNT_TOKEN; nothing changed`);
  }

  return token;
}

async function readSettings(path: string) {
  try {
    const text = await readFile(path, 'utf8');

    return text;
  } catch (error) {
    const code = findJSONField(error, 'code');

    throw new ExitError(2, `cannot read ${path} (${String(code)}); nothing changed`);
  }
}
