import { onTestFinished } from 'bun:test';
import type { ServerWebSocket } from 'bun';
import { http, passthrough } from 'msw';
import { match } from 'ts-pattern';
import { z } from 'zod';
import { server as mockServer } from '../mocks/node.ts';
import type { StubApp } from './build-stub-proxy-response.ts';
import { buildStubProxyResponse } from './build-stub-proxy-response.ts';

// impd's API on loopback, as zgeoff/impz v2.3.0 serves @impz/client 2.3.0: oRPC procedures
// with each Date in `meta`, and /exec opened by a single-use exec.ticket or the bearer token. Tests
// seed imps and answer guest commands; any other procedure fails with a 500.
interface StubImp {
  readonly name: string;
  state: 'creating' | 'running' | 'sleeping' | 'stopped' | 'error';

  // an ISO time; impd sets it when it creates the imp, so it is never empty
  lastActiveAt: string;
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
  readonly stderr?: string;
  readonly hold?: boolean;
}

// the imp a redeemed ticket opens, or null for a socket the bearer token opened, which may open any
interface ExecSocketData {
  readonly ticketImp: string | null;
}

export interface StubImpd {
  readonly url: string;
  readonly token: string;
  readonly imps: Map<string, StubImp>;

  readonly impDomain: string;
  readonly apps: Map<string, StubApp>;

  // every request through the wake proxy, as `<method> <url>`, in order
  readonly proxied: string[];

  // every procedure call, as `<router>/<procedure> <name>`, or the procedure alone for one that
  // names no imp, in order
  readonly calls: string[];
  readonly commands: StubCommand[];

  // the sockets of held commands, by imp: a held command never exits, and the destroy of its imp
  // closes its socket without an exit, as the end of the guest ends the exec
  readonly held: Map<string, ServerWebSocket<ExecSocketData>[]>;
  answerCommand: (command: StubCommand) => StubCommandAnswer;

  // live exec tickets, each to the imp it was issued for; a ticket redeems once
  readonly tickets: Map<string, string>;
}

const procedureBodySchema = z.object({ json: z.record(z.string(), z.unknown()).optional() });

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
    tickets: new Map(),
  };

  const answerRequest = async (request: Request, bunServer: Bun.Server<ExecSocketData>) => {
    const url = new URL(request.url);

    if (url.pathname === '/exec') {
      return createExecSocket(stub, request, bunServer);
    }

    if (request.headers.get('authorization') !== `Bearer ${token}`) {
      return buildRPCError(401, 'UNAUTHORIZED', 'missing or wrong token');
    }

    const procedure = url.pathname.replace(/^\/rpc\//u, '');

    // a procedure without input, such as system.info, comes with no body
    const text = await request.text();

    const raw: unknown = text === '' ? {} : JSON.parse(text);
    const body = procedureBodySchema.safeParse(raw);

    if (!body.success) {
      return buildRPCError(400, 'BAD_REQUEST', 'Input validation failed');
    }

    return buildProcedureResponse(stub, procedure, body.data.json ?? {});
  };

  const server = Bun.serve<ExecSocketData>({
    hostname: '127.0.0.1',
    port: 0,
    fetch: answerRequest,
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

function createExecSocket(
  stub: StubImpd,
  request: Request,
  bunServer: Bun.Server<ExecSocketData>,
): Response | undefined {
  const ticket = new URL(request.url).searchParams.get('ticket');

  const ticketImp = ticket === null ? null : (stub.tickets.get(ticket) ?? null);

  if (ticket !== null) {
    stub.tickets.delete(ticket);
  }

  const authorized = request.headers.get('authorization') === `Bearer ${stub.token}`;

  if (ticketImp === null && !authorized) {
    // impd answers a refused upgrade with a 401 before any socket opens
    return Response.json({ error: 'unauthorized' }, { status: 401 });
  }

  return bunServer.upgrade(request, { data: { ticketImp } })
    ? undefined
    : new Response('not a WebSocket\n', { status: 400 });
}

function buildRPCError(status: number, code: string, message: string): Response {
  // oRPC's error body: the error's JSON in the envelope, with its status as the HTTP status
  return Response.json({ json: { defined: true, code, status, message } }, { status });
}

// the version system.info reports: the impd the host pins
const stubImpdVersion = '2.3.0';

function buildProcedureResponse(
  stub: StubImpd,
  procedure: string,
  input: Record<string, unknown>,
): Response {
  const name = typeof input['name'] === 'string' ? input['name'] : null;
  const call = name === null ? procedure : `${procedure} ${name}`;

  stub.calls.push(call);

  if (procedure === 'system/info') {
    return buildRPCResult({ version: stubImpdVersion, features: { execRequire: true } });
  }

  if (procedure === 'imps/list') {
    return buildRPCResult([...stub.imps.values()].map((each) => toImpRecord(each)));
  }

  const imp = name === null ? undefined : stub.imps.get(name);

  if (procedure === 'imps/create') {
    if (imp !== undefined) {
      return buildRPCError(409, 'CONFLICT', `an imp named ${name} exists`);
    }

    const created: StubImp = {
      name: String(name),
      state: 'running',
      lastActiveAt: new Date().toISOString(),
      httpPort: Number(input['httpPort'] ?? 8080),
      image: String(input['image']),
      memoryMib: Number(input['memoryMib']),
      backup: input['backup'] !== false,
      grants: [],
    };

    stub.imps.set(created.name, created);

    return buildRPCResult(toImpRecord(created));
  }

  if (imp === undefined) {
    return buildRPCError(404, 'NOT_FOUND', `no imp named ${name}`);
  }

  return match(procedure)
    .with('imps/get', () => buildRPCResult(toImpRecord(imp)))
    .with('imps/sleep', () => {
      imp.state = 'sleeping';

      return buildRPCResult(toImpRecord(imp));
    })
    .with('imps/wake', () => {
      imp.state = 'running';

      return buildRPCResult(toImpRecord(imp));
    })
    .with('imps/update', () => {
      imp.httpPort = Number(input['httpPort']);

      return buildRPCResult(toImpRecord(imp));
    })
    .with('imps/destroy', () => {
      stub.imps.delete(imp.name);

      for (const socket of stub.held.get(imp.name) ?? []) {
        socket.close();
      }

      return buildRPCResult({});
    })
    .with('grants/list', () => buildRPCResult(imp.grants))
    .with('grants/add', () => {
      imp.grants.push(String(input['secret']));

      return buildRPCResult({});
    })
    .with('exec/ticket', () => {
      const ticket = `stub-ticket.${crypto.randomUUID()}`;

      stub.tickets.set(ticket, imp.name);

      return buildRPCResult({ ticket, expiresAt: new Date(Date.now() + 30_000) });
    })
    .otherwise(
      () => new Response(`not impd: start-stub-impd.ts has no ${procedure}\n`, { status: 500 }),
    );
}

function buildRPCResult(output: unknown): Response {
  const meta: (string | number)[][] = [];
  const json = encodeRPCValue(output, [], meta);
  const body = meta.length === 0 ? { json } : { json, meta };

  return Response.json(body);
}

function encodeRPCValue(
  value: unknown,
  path: readonly (string | number)[],
  meta: (string | number)[][],
): unknown {
  if (value instanceof Date) {
    // oRPC's RPC serializer sends a Date as its ISO string, with its path in `meta` under type 1,
    // oRPC's DATE
    meta.push([1, ...path]);

    return value.toISOString();
  }

  if (Array.isArray(value)) {
    return value.map((each, index) => encodeRPCValue(each, [...path, index], meta));
  }

  if (typeof value === 'object' && value !== null) {
    return Object.fromEntries(
      Object.entries(value).map(([key, each]) => [key, encodeRPCValue(each, [...path, key], meta)]),
    );
  }

  return value;
}

function toImpRecord(imp: StubImp) {
  return {
    id: `imp-${imp.name}`,
    name: imp.name,
    image: imp.image,
    state: imp.state,
    httpPort: imp.httpPort,
    lastActiveAt: new Date(imp.lastActiveAt),
  };
}

const execMessageSchema = z.object({
  type: z.string(),
  name: z.string().optional(),
  argv: z.array(z.string()).optional(),
  require: z.array(z.string()).optional(),
});

function runStubCommand(
  stub: StubImpd,
  socket: ServerWebSocket<ExecSocketData>,
  raw: string | Buffer,
): void {
  const parsed: unknown = JSON.parse(String(raw));
  const result = execMessageSchema.safeParse(parsed);

  if (!result.success) {
    socket.send(
      JSON.stringify({ type: 'error', code: 'BAD_REQUEST', message: 'not an exec message' }),
    );

    socket.close();

    return;
  }

  const message = result.data;

  if (message.type !== 'start') {
    return;
  }

  const imp = stub.imps.get(message.name ?? '');

  // a ticket opens only the imp it was issued for
  if (socket.data.ticketImp !== null && socket.data.ticketImp !== message.name) {
    socket.send(
      JSON.stringify({ type: 'error', code: 'FORBIDDEN', message: 'the ticket opens another imp' }),
    );

    socket.close();

    return;
  }

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
    socket.send(buildExecFrame(1, answer.stdout));
  }

  if (answer.stderr !== undefined) {
    socket.send(buildExecFrame(2, answer.stderr));
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

function buildExecFrame(channel: 1 | 2, text: string): Uint8Array {
  const bytes = new TextEncoder().encode(text);
  const frame = new Uint8Array(bytes.byteLength + 1);

  // impd's binary frame is one channel byte, 1 for stdout or 2 for stderr, then the bytes
  frame[0] = channel;

  frame.set(bytes, 1);

  return frame;
}
