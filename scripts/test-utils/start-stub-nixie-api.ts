import { onTestFinished } from 'bun:test';
import { HttpResponse, http } from 'msw';
import { findJSONField } from '../find-json-field.ts';
import { server } from '../mocks/node.ts';
import { buildStubNixieRecord } from './build-stub-nixie-record.ts';
import type { StubStream } from './start-stub-nixie-stream.ts';
import { startStubNixieStream } from './start-stub-nixie-stream.ts';

export interface StubNixieAPIOptions {
  readonly url: string;

  // the codes enrol accepts, each once
  readonly enrolCodes: readonly string[];

  readonly sequences: readonly number[];
  readonly keepaliveMs: number | null;
  readonly closeAfterMs: number | null;
}

export interface StubNixieAPI {
  readonly sessions: readonly { readonly sessionID: string; readonly revoked: boolean }[];

  readonly calls: readonly string[];
  readonly waitForStream: () => Promise<void>;

  readonly appendRecord: () => void;

  readonly createSession: () => string;
}

export function startStubNixieAPI(options: StubNixieAPIOptions): StubNixieAPI {
  const state: StubState = {
    options,
    codes: new Set(options.enrolCodes),
    sessions: [],
    sequences: [...options.sequences],
    calls: [],
    streams: [],
    opened: Promise.withResolvers<void>(),
  };

  onTestFinished(() => {
    for (const stream of state.streams) {
      stream.stop();
    }
  });

  server.use(...buildHandlers(state));

  return {
    get sessions() {
      return state.sessions.map((row) => ({ sessionID: row.sessionID, revoked: row.revoked }));
    },
    calls: state.calls,
    waitForStream: () => state.opened.promise,
    appendRecord: () => {
      createRecord(state);
    },
    createSession: () => createSessionRow(state).token,
  };
}

interface StubState {
  readonly options: StubNixieAPIOptions;
  readonly codes: Set<string>;
  readonly sessions: { readonly sessionID: string; readonly token: string; revoked: boolean }[];
  readonly sequences: number[];
  readonly calls: string[];
  readonly streams: StubStream[];
  readonly opened: PromiseWithResolvers<void>;
}

type Input = (key: string) => unknown;

function buildHandlers(state: StubState) {
  return [
    makeRoute(state, 'sessions/enrol', (_request, input) => createSession(state, input)),
    makeRoute(state, 'sessions/revoke', (_request, input) => updateRevoked(state, input)),
    makeRoute(state, 'conversation/read', (_request, input) => buildReadResponse(state, input)),
    makeRoute(state, 'log/follow', (request, input) => startFollow(state, { request, input })),
  ];
}

function makeRoute(
  state: StubState,
  procedure: string,
  answer: (request: Request, input: Input) => Response,
) {
  return http.post(new URL(`/rpc/${procedure}`, state.options.url).href, async (info) => {
    state.calls.push(procedure);

    // nixie's API refuses a call without the client header before any procedure runs
    if ((info.request.headers.get('x-nixie-client') ?? '') === '') {
      return new HttpResponse('the client header is missing', { status: 403 });
    }

    const body: unknown = await info.request.json();

    // every procedure but enrol needs a live session
    if (procedure !== 'sessions/enrol' && findSession(state, info.request) === undefined) {
      return buildError(401, 'UNAUTHORIZED', 'The device session is missing, lapsed or revoked');
    }

    return answer(info.request, (key) => findJSONField(findJSONField(body, 'json'), key));
  });
}

function findSession(state: StubState, request: Request) {
  const match = /^Bearer (?<token>\S+)$/u.exec(request.headers.get('authorization') ?? '');

  return state.sessions.find((row) => row.token === match?.groups?.['token'] && !row.revoked);
}

function buildError(status: number, code: string, message: string): Response {
  // a defined error in the RPC protocol of @orpc/server 1.15.4
  return HttpResponse.json({ json: { defined: true, code, status, message } }, { status });
}

function createSession(state: StubState, input: Input): Response {
  if (input('tokenDelivery') !== 'bearer' || !state.codes.delete(String(input('code')))) {
    return buildError(
      400,
      'ENROLMENT_CODE_INVALID',
      'The enrolment code is unknown, used or lapsed',
    );
  }

  const session = createSessionRow(state);

  return HttpResponse.json({ json: { sessionID: session.sessionID, token: session.token } });
}

function updateRevoked(state: StubState, input: Input): Response {
  const session = state.sessions.find((row) => row.sessionID === input('sessionID'));

  if (session === undefined) {
    return buildError(404, 'SESSION_NOT_FOUND', 'No session has this ID');
  }

  session.revoked = true;

  return HttpResponse.json({
    json: { revokedAt: new Date().toISOString() },
    meta: [[1, 'revokedAt']],
  });
}

function buildReadResponse(state: StubState, input: Input): Response {
  const beforeSequence = input('beforeSequence');
  const pageLimit = input('limit');
  const before = typeof beforeSequence === 'number' ? beforeSequence : Infinity;
  const limit = typeof pageLimit === 'number' ? pageLimit : 50;
  const earlier = state.sequences.filter((sequence) => sequence < before);
  const page = earlier.slice(-limit);

  return HttpResponse.json({
    json: {
      hasEarlier: earlier.length > page.length,
      readAtSequence: state.sequences.at(-1) ?? 0,
      records: page.map((sequence) => buildStubNixieRecord(sequence)),
    },
    meta: page.map((_sequence, index) => [1, 'records', index, 'recordedAt']),
  });
}

interface FollowCall {
  readonly request: Request;
  readonly input: Input;
}

function startFollow(state: StubState, call: FollowCall): Response {
  const stream = startStubNixieStream({
    keepaliveMs: state.options.keepaliveMs,
    closeAfterMs: state.options.closeAfterMs,
    signal: call.request.signal,
  });

  state.streams.push(stream);

  for (const sequence of state.sequences.filter(
    (row) => row > Number(call.input('afterSequence')),
  )) {
    stream.sendRecord(sequence);
  }

  state.opened.resolve();

  return new HttpResponse(stream.body, { headers: { 'content-type': 'text/event-stream' } });
}

function createRecord(state: StubState): void {
  const sequence = (state.sequences.at(-1) ?? 0) + 1;

  state.sequences.push(sequence);

  for (const stream of state.streams) {
    stream.sendRecord(sequence);
  }
}

function createSessionRow(state: StubState) {
  const session = { sessionID: crypto.randomUUID(), token: crypto.randomUUID(), revoked: false };

  state.sessions.push(session);

  return session;
}
