/* oxlint-disable max-lines, max-lines-per-function, max-statements, typescript/no-unsafe-type-assertion */
import { onTestFinished } from 'bun:test';
import type { ServerWebSocket } from 'bun';
import { http, passthrough } from 'msw';
import { server as mockServer } from '../mocks/node.ts';
import type { StubApp } from './build-stub-proxy-response.ts';
import { buildStubProxyResponse } from './build-stub-proxy-response.ts';

// impd's API on a loopback port over real HTTP and WebSocket: the preview service's oRPC procedures
// in imp 1.4.4's {"json": …} envelope, and zgeoff/imp's exec-protocol.ts /exec. Tests seed imps and
// answer guest commands through `answerCommand`; any other procedure fails with a 500.
interface StubImp {
  readonly name: string;
  state: 'creating' | 'running' | 'sleeping' | 'stopped' | 'error';
  lastActiveAt: string | null;
  httpPort: number;
  readonly image: string;
  readonly memoryMib: number;
  readonly backup: boolean;
  readonly grants: string[];
}

interface StubCommand {
  readonly imp: string;
  readonly argv: readonly string[];
  readonly require: readonly string[];
}

interface StubCommandAnswer {
  readonly code: number | null;
  readonly stdout?: string;
  readonly hold?: boolean;
}

export interface StubImpd {
  readonly url: string;
  readonly token: string;
  readonly imps: Map<string, StubImp>;

  // the domain of impd's wake proxy, which the service's impDomain setting names
  readonly impDomain: string;
  readonly apps: Map<string, StubApp>;

  // every request through the wake proxy, as `<method> <url>`, in order
  readonly proxied: string[];

  // every procedure call, as `<router>/<procedure> <name>`, in order
  readonly calls: string[];
  readonly commands: StubCommand[];

  // the sockets of held commands, by imp: a held command never exits, and the destroy of its imp
  // closes its socket without an exit, as the end of the guest ends the exec
  readonly held: Map<string, ServerWebSocket<ExecSocketData>[]>;
  answerCommand: (command: StubCommand) => StubCommandAnswer;
}

interface ExecSocketData {
  readonly authorized: boolean;
}

export function startStubImpd(): StubImpd {
  const token = 'imp_stubpreview.stub-secret';

  const stub: StubImpd = {
    url: '',
    token,
    imps: new Map(),
    impDomain: 'imps.example.test',
    apps: new Map(),
    proxied: [],
    calls: [],
    commands: [],
    held: new Map(),
    answerCommand: () => ({ code: 0 }),
  };

  const server = Bun.serve<ExecSocketData>({
    hostname: '127.0.0.1',
    port: 0,
    fetch: async (request, bunServer) => {
      const url = new URL(request.url);

      const authorized = request.headers.get('authorization') === `Bearer ${token}`;

      if (url.pathname === '/exec') {
        return bunServer.upgrade(request, { data: { authorized } })
          ? undefined
          : new Response('not a WebSocket\n', { status: 400 });
      }

      if (!authorized) {
        return buildRPCError(401, 'UNAUTHORIZED', 'missing or wrong token');
      }

      const procedure = url.pathname.replace(/^\/rpc\//u, '');
      const body = (await request.json()) as { readonly json: Record<string, unknown> };

      return buildProcedureResponse(stub, procedure, body.json);
    },
    websocket: {
      message: (socket: ServerWebSocket<ExecSocketData>, raw) => {
        runStubCommand(stub, socket, raw);
      },
    },
  });

  onTestFinished(() => server.stop(true));

  const url = `http://127.0.0.1:${server.port}`;

  // the service's fetch to the stub is real loopback traffic, which MSW lets through
  mockServer.use(
    http.all(`${url}/*`, () => passthrough()),
    http.all(`https://*.${stub.impDomain}/*`, (info) => buildStubProxyResponse(stub, info.request)),
  );

  return Object.assign(stub, { url });
}

function buildProcedureResponse(
  stub: StubImpd,
  procedure: string,
  input: Record<string, unknown>,
): Response {
  const name = String(input['name']);

  stub.calls.push(`${procedure} ${name}`);

  const imp = stub.imps.get(name);

  if (procedure === 'imps/list') {
    return buildRPCResult([...stub.imps.values()].map((each) => toImpRecord(each)));
  }

  if (procedure === 'imps/create') {
    if (imp !== undefined) {
      return buildRPCError(409, 'CONFLICT', `an imp named ${name} exists`);
    }

    const created: StubImp = {
      name,
      state: 'running',
      lastActiveAt: null,
      httpPort: Number(input['httpPort'] ?? 8080),
      image: String(input['image']),
      memoryMib: Number(input['memoryMib']),
      backup: input['backup'] !== false,
      grants: [],
    };

    stub.imps.set(name, created);

    return buildRPCResult(toImpRecord(created));
  }

  if (imp === undefined) {
    return buildRPCError(404, 'NOT_FOUND', `no imp named ${name}`);
  }

  switch (procedure) {
    case 'imps/get': {
      return buildRPCResult(toImpRecord(imp));
    }

    case 'imps/sleep': {
      imp.state = 'sleeping';

      return buildRPCResult(toImpRecord(imp));
    }

    case 'imps/wake': {
      imp.state = 'running';

      return buildRPCResult(toImpRecord(imp));
    }

    case 'imps/update': {
      imp.httpPort = Number(input['httpPort']);

      return buildRPCResult(toImpRecord(imp));
    }

    case 'imps/destroy': {
      stub.imps.delete(name);

      for (const socket of stub.held.get(name) ?? []) {
        socket.close();
      }

      return buildRPCResult({});
    }

    case 'grants/list': {
      return buildRPCResult(imp.grants);
    }

    case 'grants/add': {
      imp.grants.push(String(input['secret']));

      return buildRPCResult({});
    }

    default: {
      return new Response(`not impd: start-stub-impd.ts has no ${procedure}\n`, { status: 500 });
    }
  }
}

// the fields of impd's ImpSchema that the service reads, beside two it ignores
function toImpRecord(imp: StubImp) {
  return {
    id: `imp-${imp.name}`,
    name: imp.name,
    image: imp.image,
    state: imp.state,
    httpPort: imp.httpPort,
    lastActiveAt: imp.lastActiveAt,
  };
}

function buildRPCResult(output: unknown): Response {
  return Response.json({ json: output });
}

// oRPC's error body: the ORPCError's JSON in the envelope, with its status as the HTTP status
function buildRPCError(status: number, code: string, message: string): Response {
  return Response.json({ json: { defined: true, code, status, message } }, { status });
}

function runStubCommand(
  stub: StubImpd,
  socket: ServerWebSocket<ExecSocketData>,
  raw: string | Buffer,
): void {
  const message = JSON.parse(String(raw)) as {
    readonly type: string;
    readonly name?: string;
    readonly argv?: string[];
    readonly require?: string[];
  };

  if (message.type !== 'start') {
    return;
  }

  if (!socket.data.authorized) {
    socket.send(
      JSON.stringify({ type: 'error', code: 'UNAUTHORIZED', message: 'missing or wrong token' }),
    );

    socket.close();

    return;
  }

  const imp = stub.imps.get(message.name ?? '');

  if (imp === undefined) {
    socket.send(
      JSON.stringify({ type: 'error', code: 'NOT_FOUND', message: `no imp named ${message.name}` }),
    );

    socket.close();

    return;
  }

  // an exec wakes a sleeping imp
  imp.state = 'running';

  const command = { imp: imp.name, argv: message.argv ?? [], require: message.require ?? [] };

  stub.commands.push(command);

  const answer = stub.answerCommand(command);

  socket.send(JSON.stringify({ type: 'started', pid: 4242 }));

  if (answer.stdout !== undefined) {
    const text = new TextEncoder().encode(answer.stdout);
    const frame = new Uint8Array(text.byteLength + 1);

    frame[0] = 1;

    frame.set(text, 1);
    socket.send(frame);
  }

  if (answer.hold === true) {
    stub.held.set(imp.name, [...(stub.held.get(imp.name) ?? []), socket]);

    return;
  }

  socket.send(
    JSON.stringify({
      type: 'exit',
      code: answer.code,
      signal: answer.code === null ? 'SIGKILL' : null,
    }),
  );

  socket.close();
}
