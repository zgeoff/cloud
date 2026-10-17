import { ORPCError } from '@orpc/client';
import {
  StandardRPCJsonSerializer,
  StandardRPCLinkCodec,
  StandardRPCSerializer,
} from '@orpc/client/standard';
import { buildNixieHeaders } from '../build-nixie-headers.ts';
import type { paths } from './openapi.d.ts';

// The one place that knows how a call reaches nixie's API, in oRPC's RPC protocol under /rpc,
// with oRPC's own codec. The procedures and their types come from nixie's contract document, so a
// procedure that nixie drops or renames fails the type check.
type ToProcedure<Path> = Path extends `/${infer Procedure}` ? Procedure : never;

// a procedure's path, such as sessions/enrol
export type NixieProcedure = ToProcedure<keyof paths>;

type Operation<Procedure extends NixieProcedure> = paths[`/${Procedure}`]['post'];

type NixieInput<Procedure extends NixieProcedure> = Operation<Procedure>['requestBody'] extends {
  content: { 'application/json': infer Input };
}
  ? Input
  : undefined;

// what a call answers on success; a stream's answer has no JSON output
export type NixieOutput<Procedure extends NixieProcedure> =
  Operation<Procedure>['responses'][200]['content'] extends { 'application/json': infer Output }
    ? Output
    : never;

export interface NixieRequest<Procedure extends NixieProcedure> {
  // nixie's origin
  readonly url: string;
  readonly token: string | null;
  readonly procedure: Procedure;
  readonly input: NixieInput<Procedure>;
  readonly signal?: AbortSignal;
}

// the output on success, or nixie's error code, null when the answer carries none
export type NixieAnswer =
  | { readonly ok: true; readonly output: unknown }
  | { readonly ok: false; readonly code: string | null };

// the call's origin and session, which the codec reads to build each request
interface NixieContext {
  readonly url: string;
  readonly token: string | null;
}

// the procedure's path joins the base URL, so every call goes under /rpc
const codec = new StandardRPCLinkCodec<NixieContext>(
  new StandardRPCSerializer(new StandardRPCJsonSerializer()),
  {
    url: (options) => new URL('/rpc', options.context.url),
    headers: (options) => buildNixieHeaders(options.context.token),
  },
);

// The fetch request for one call
export async function encodeNixieRequest<Procedure extends NixieProcedure>(
  request: Readonly<NixieRequest<Procedure>>,
): Promise<Request> {
  const encoded = await codec.encode(request.procedure.split('/'), request.input, {
    context: { url: request.url, token: request.token },
    ...(request.signal === undefined ? {} : { signal: request.signal }),
  });

  // oRPC encodes an input with a file in it as a form, but the contract types every input that
  // these calls send as JSON
  return new Request(encoded.url.href, {
    method: encoded.method,
    headers: toHeaders(encoded.headers),
    body: JSON.stringify(encoded.body),
    ...(encoded.signal === undefined ? {} : { signal: encoded.signal }),
  });
}

// An answer's status and body text, decoded: a status below 400 decodes the output, and an error
// status decodes nixie's error. A body that oRPC cannot decode carries no code.
export async function decodeNixieAnswer(status: number, text: string): Promise<NixieAnswer> {
  try {
    const output = await codec.decode({
      status,
      headers: {},
      body: () => Promise.try(() => parseBody(text)),
    });

    return { ok: true, output };
  } catch (error) {
    const code: unknown = error instanceof ORPCError ? error.code : null;

    return { ok: false, code: typeof code === 'string' ? code : null };
  }
}

function toHeaders(
  headers: Readonly<Record<string, string | readonly string[] | undefined>>,
): Headers {
  const result = new Headers();

  for (const [name, value] of Object.entries(headers)) {
    for (const item of typeof value === 'string' ? [value] : (value ?? [])) {
      result.append(name, item);
    }
  }

  return result;
}

// an empty body reads as no body, as oRPC's fetch adapter reads it; text that is not JSON throws,
// which the codec reports as a body it cannot parse
function parseBody(text: string): unknown {
  if (text === '') {
    return undefined;
  }

  const value: unknown = JSON.parse(text);

  return value;
}
