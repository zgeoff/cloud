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
}

// The impd calls the service makes, each confined by impd to the imps its token names
export interface ImpdClient {
  readonly createImp: (options: ImpCreateOptions) => Promise<ImpActivity>;
  readonly findImp: (name: string) => Promise<ImpActivity | null>;
  readonly readImps: () => Promise<ImpActivity[]>;
  readonly sleepImp: (name: string) => Promise<void>;
  readonly wakeImp: (name: string) => Promise<void>;
  readonly updateHTTPPort: (name: string, httpPort: number) => Promise<void>;
  readonly removeImp: (name: string) => Promise<void>;
  readonly createGrant: (name: string, secret: string) => Promise<void>;
  readonly runCommand: (
    name: string,
    argv: readonly string[],
    options?: CommandOptions,
  ) => Promise<CommandResult>;
}

// An impd error, with the code its contract defines, such as NOT_FOUND or LEASED
class ImpdError extends Error {
  readonly code: string;

  constructor(code: string, message: string) {
    super(`impd ${code}: ${message}`);

    this.name = 'ImpdError';
    this.code = code;
  }
}

// impd's API (zgeoff/imp docs/architecture/control/api.md) is oRPC: a POST to
// /rpc/<router>/<procedure> with the input in a {"json": …} envelope. The service speaks it
// without imp's client package, so it runs with no dependency beyond Bun.
export function buildImpdClient(
  baseURL: string,
  token: string,
  webSocket: typeof WebSocket = globalThis.WebSocket,
): ImpdClient {
  const sendRPC = (procedure: string, input: unknown): Promise<unknown> =>
    sendImpdRPC({ baseURL, token, procedure, input });

  return {
    createImp: async (options) => {
      const imp = await sendRPC('imps/create', { ...options, backup: false });

      return toImpActivity(imp);
    },
    findImp: (name) => findImpActivity(sendRPC, name),
    readImps: async () => {
      const imps = await sendRPC('imps/list', {});

      return Array.isArray(imps) ? imps.map((imp) => toImpActivity(imp)) : [];
    },
    sleepImp: async (name) => {
      await sendRPC('imps/sleep', { name });
    },
    wakeImp: async (name) => {
      await sendRPC('imps/wake', { name });
    },
    updateHTTPPort: async (name, httpPort) => {
      await sendRPC('imps/update', { name, httpPort });
    },
    removeImp: async (name) => {
      await sendRPC('imps/destroy', { name });
    },
    createGrant: async (name, secret) => {
      await sendRPC('grants/add', { name, secret });
    },
    runCommand: (name, argv, options = {}) => {
      const require = options.requireBroker === true ? { require: ['broker'] } : {};

      return runExec(
        { baseURL, token, webSocket },
        { type: 'start', name, argv, tty: false, ...require },
      );
    },
  };
}

interface ImpdRPC {
  readonly baseURL: string;
  readonly token: string;
  readonly procedure: string;
  readonly input: unknown;
}

interface RPCErrorBody {
  readonly code?: unknown;
  readonly message?: unknown;
}

async function sendImpdRPC(rpc: ImpdRPC): Promise<unknown> {
  const response = await fetch(`${rpc.baseURL}/rpc/${rpc.procedure}`, {
    method: 'POST',
    headers: { authorization: `Bearer ${rpc.token}`, 'content-type': 'application/json' },
    body: JSON.stringify({ json: rpc.input }),
  });

  const body = (await response.json()) as { readonly json?: unknown };

  if (response.ok) {
    return body.json;
  }

  const error = (body.json ?? {}) as RPCErrorBody;
  const code = typeof error.code === 'string' ? error.code : `HTTP ${response.status}`;
  const message = typeof error.message === 'string' ? error.message : response.statusText;

  throw new ImpdError(code, message);
}

async function findImpActivity(
  sendRPC: (procedure: string, input: unknown) => Promise<unknown>,
  name: string,
): Promise<ImpActivity | null> {
  try {
    const imp = await sendRPC('imps/get', { name });

    return toImpActivity(imp);
  } catch (error) {
    if (error instanceof ImpdError && error.code === 'NOT_FOUND') {
      return null;
    }

    throw error;
  }
}

interface ImpRecord {
  readonly name: string;
  readonly state: ImpActivity['state'];
  readonly lastActiveAt?: string | null;
}

// impd's imp record carries far more; lastActiveAt is a Date in the contract, which oRPC sends as
// an ISO string
function toImpActivity(value: unknown): ImpActivity {
  const imp = value as ImpRecord;
  const lastActiveAt = typeof imp.lastActiveAt === 'string' ? new Date(imp.lastActiveAt) : null;

  return { name: imp.name, state: imp.state, lastActiveAt };
}

interface ExecServerMessage {
  readonly type: string;
  readonly code?: number | string | null;
  readonly message?: string;
}

interface ExecTarget {
  readonly baseURL: string;
  readonly token: string;
  readonly webSocket: typeof WebSocket;
}

// impd's /exec WebSocket (zgeoff/imp packages/api/src/protocols/exec-protocol.ts): a JSON
// `start`, then binary frames of one channel byte and the bytes, then an `exit` or an `error`.
// The command's stdin closes once impd reports it started.
function runExec(impd: ExecTarget, start: object): Promise<CommandResult> {
  const result = Promise.withResolvers<CommandResult>();
  const Socket = impd.webSocket;

  const socket = new Socket(`${impd.baseURL.replace(/^http/u, 'ws')}/exec`, {
    headers: { authorization: `Bearer ${impd.token}` },
  });

  const decoder = new TextDecoder();

  const state = { output: '' };

  socket.binaryType = 'arraybuffer';

  socket.addEventListener('open', () => {
    socket.send(JSON.stringify(start));
  });

  socket.addEventListener('message', (event) => {
    if (typeof event.data !== 'string') {
      state.output += toFrameText(decoder, event.data as ArrayBuffer);

      return;
    }

    const message = JSON.parse(event.data) as ExecServerMessage;

    if (message.type === 'started') {
      socket.send(JSON.stringify({ type: 'stdin_eof' }));

      return;
    }

    if (message.type === 'exit' || message.type === 'error') {
      emitExecResult(result, message, state.output);

      socket.close();
    }
  });

  // a promise that already settled ignores this reject
  socket.addEventListener('close', () => {
    result.reject(new ImpdError('EXEC_CLOSED', 'the exec socket closed before the command exited'));
  });

  return result.promise;
}

// impd's `exit` carries a null code when a signal ended the command
function emitExecResult(
  result: PromiseWithResolvers<CommandResult>,
  message: ExecServerMessage,
  output: string,
): void {
  if (message.type === 'exit') {
    result.resolve({ code: typeof message.code === 'number' ? message.code : null, output });
  } else {
    result.reject(new ImpdError(String(message.code ?? 'EXEC_ERROR'), message.message ?? ''));
  }
}

// a binary frame is one channel byte, stdout or stderr, then the bytes
function toFrameText(decoder: TextDecoder, frame: ArrayBuffer): string {
  return decoder.decode(new Uint8Array(frame).subarray(1), { stream: true });
}
