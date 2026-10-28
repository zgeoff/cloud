import { ORPCError } from '@orpc/client';
import {
  StandardRPCJsonSerializer,
  StandardRPCLinkCodec,
  StandardRPCSerializer,
} from '@orpc/client/standard';
import { buildNixieHeaders } from '../build-nixie-headers.ts';
import type { paths } from './openapi.d.ts';

// The procedures and their types come from nixie's contract document, so a procedure that nixie
// drops or renames fails the type check.
type ToProcedure<Path> = Path extends `/${infer Procedure}` ? Procedure : never;

export type NixieProcedure = ToProcedure<keyof paths>;

type Operation<Procedure extends NixieProcedure> = paths[`/${Procedure}`]['post'];

// it distributes over a union of procedures, so a request for any one of several procedures takes
// any one of their inputs
export type NixieInput<Procedure extends NixieProcedure> = Procedure extends NixieProcedure
  ? Operation<Procedure>['requestBody'] extends { content: { 'application/json': infer Input } }
    ? Input
    : undefined
  : never;

// a stream's answer has no JSON output
export type NixieOutput<Procedure extends NixieProcedure> =
  Operation<Procedure>['responses'][200]['content'] extends { 'application/json': infer Output }
    ? Output
    : never;

export interface NixieRequest<Procedure extends NixieProcedure> {
  readonly url: string;
  readonly token: string | null;
  readonly procedure: Procedure;
  readonly input: NixieInput<Procedure>;
  readonly signal?: AbortSignal;
}

export type NixieAnswer =
  | { readonly ok: true; readonly output: unknown }
  | {
      readonly ok: false;
      readonly code: string | null;

      // false when the body is no error that nixie's contract defines, for which oRPC makes the
      // code up from the HTTP status, as for a proxy's own 401
      readonly isDefined: boolean;
    };

interface NixieContext {
  readonly url: string;
  readonly token: string | null;
}

// the procedure's path joins the base URL, so every call goes under rpc/ below the base URL's own
// path, which a proxy such as the k3s API's service proxy puts in front of nixie's
const codec = new StandardRPCLinkCodec<NixieContext>(
  new StandardRPCSerializer(new StandardRPCJsonSerializer()),
  {
    url: (options) => new URL('rpc', toDirectoryURL(options.context.url)),
    headers: (options) => buildNixieHeaders(options.context.token),
  },
);

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

    return {
      ok: false,
      code: typeof code === 'string' ? code : null,
      isDefined: error instanceof ORPCError && error.defined,
    };
  }
}

function toDirectoryURL(url: string): string {
  return url.endsWith('/') ? url : `${url}/`;
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

function parseBody(text: string): unknown {
  // an empty body reads as no body, as oRPC's fetch adapter reads it
  if (text === '') {
    return undefined;
  }

  // text that is not JSON throws, which the codec reports as a body it cannot parse
  const value: unknown = JSON.parse(text);

  return value;
}
