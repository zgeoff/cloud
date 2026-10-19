import type { ExecHandle, Imp, ImpClient } from '@impz/client';
import { ExecError, ORPCError, createImpClient } from '@impz/client';
import type { ImpActivity } from './plan-slot-evictions.ts';

interface ImpCreateOptions {
  readonly name: string;
  readonly image: string;
  readonly memoryMib: number;
  readonly httpPort: number;
}

interface CommandResult {
  // null when a signal ended the command
  readonly code: number | null;

  // stdout and stderr, interleaved as they arrived
  readonly output: string;
}

interface CommandOptions {
  // impd refuses to start the command unless the broker's proxy and CA reach it, so a clone never
  // runs without the broker's GitHub credential
  readonly requireBroker?: boolean;

  readonly signal?: AbortSignal;
}

// impd confines each call to the imps its token names
export interface ImpdClient {
  readonly createImp: (options: ImpCreateOptions) => Promise<ImpActivity>;
  readonly findImp: (name: string) => Promise<ImpActivity | null>;
  readonly readImps: () => Promise<ImpActivity[]>;
  readonly sleepImp: (name: string) => Promise<void>;
  readonly wakeImp: (name: string) => Promise<void>;
  readonly updateHTTPPort: (name: string, httpPort: number) => Promise<void>;
  readonly removeImp: (name: string) => Promise<void>;
  readonly installGrant: (name: string, secret: string) => Promise<void>;
  readonly runCommand: (
    name: string,
    argv: readonly string[],
    options?: CommandOptions,
  ) => Promise<CommandResult>;
}

export function buildImpdClient(
  baseURL: string,
  token: string,
  webSocket: typeof WebSocket = globalThis.WebSocket,
): ImpdClient {
  const Socket = webSocket;

  // imp's typed client, so a change to impd's contract fails the type check here
  const client = createImpClient({ url: baseURL, token, connect: (url) => new Socket(url) });

  return {
    createImp: (options) =>
      withImpdErrors(async () => {
        const imp = await client.imps.create({ ...options, backup: false });

        return toImpActivity(imp);
      }),
    findImp: (name) => findImpActivity(client, name),
    readImps: () =>
      withImpdErrors(async () => {
        const imps = await client.imps.list({});

        return imps.map((imp) => toImpActivity(imp));
      }),
    sleepImp: (name) =>
      withImpdErrors(async () => {
        await client.imps.sleep({ name });
      }),
    wakeImp: (name) =>
      withImpdErrors(async () => {
        await client.imps.wake({ name });
      }),
    updateHTTPPort: (name, httpPort) =>
      withImpdErrors(async () => {
        await client.imps.update({ name, httpPort });
      }),
    removeImp: (name) =>
      withImpdErrors(async () => {
        await client.imps.destroy({ name });
      }),
    installGrant: (name, secret) => withImpdErrors(() => installImpGrant(client, name, secret)),
    runCommand: (name, argv, options = {}) =>
      withImpdErrors(async () => {
        const require = options.requireBroker === true ? { require: ['broker'] as const } : {};
        const signal = options.signal === undefined ? {} : { signal: options.signal };

        const handle = await client.openExec(name, argv, { ...require, ...signal });

        return readCommandResult(handle);
      }),
  };
}

class ImpdError extends Error {
  readonly code: string;

  constructor(code: string, message: string, cause: unknown) {
    // the code goes in the message, so a log line or a commit status names it
    super(`impd ${code}: ${message}`, { cause });

    this.name = 'ImpdError';
    this.code = code;
  }
}

async function withImpdErrors<T>(call: () => Promise<T>): Promise<T> {
  try {
    return await call();
  } catch (error) {
    if (error instanceof ORPCError || error instanceof ExecError) {
      throw new ImpdError(String(error.code), error.message, error);
    }

    throw error;
  }
}

async function findImpActivity(client: ImpClient, name: string): Promise<ImpActivity | null> {
  try {
    return await withImpdErrors(async () => {
      const imp = await client.imps.get({ name });

      return toImpActivity(imp);
    });
  } catch (error) {
    if (error instanceof ImpdError && error.code === 'NOT_FOUND') {
      return null;
    }

    throw error;
  }
}

function toImpActivity(imp: Imp): ImpActivity {
  return { name: imp.name, state: imp.state, lastActiveAt: imp.lastActiveAt };
}

async function installImpGrant(client: ImpClient, name: string, secret: string): Promise<void> {
  const granted = await client.grants.list({ name });

  if (granted.includes(secret)) {
    return;
  }

  await client.grants.add({ name, secret });
}

async function readCommandResult(handle: ExecHandle): Promise<CommandResult> {
  const texts: string[] = [];

  const reads = Promise.all([
    readStreamTexts(handle.stdout, texts),
    readStreamTexts(handle.stderr, texts),
  ]);

  await handle.closeStdin();

  const [exit] = await Promise.all([handle.exit, reads]);

  return { code: exit.code, output: texts.join('') };
}

async function readStreamTexts(stream: ReadableStream<Uint8Array>, texts: string[]): Promise<void> {
  const decoder = new TextDecoder();

  for await (const chunk of stream) {
    texts.push(decoder.decode(chunk, { stream: true }));
  }

  texts.push(decoder.decode());
}
