import type { NixieProcedure, NixieRequest } from './nixie-api/nixie-rpc.ts';
import { decodeNixieAnswer, encodeNixieRequest } from './nixie-api/nixie-rpc.ts';

export interface NixieCall<Procedure extends NixieProcedure, T> extends NixieRequest<Procedure> {
  // the output is whatever nixie answered, so the check reads it at run time
  readonly parse: (output: unknown) => T | undefined;
}

export type RPCResult<T> =
  | { readonly ok: true; readonly value: T }
  | { readonly ok: false; readonly error: string };

export async function sendNixieRPC<Procedure extends NixieProcedure, T>(
  call: Readonly<NixieCall<Procedure, T>>,
): Promise<RPCResult<T>> {
  const request = await encodeNixieRequest(call);

  const response = await fetch(request).catch(
    (error: unknown) => new Error(`${call.procedure} failed: ${String(error)}`),
  );

  if (response instanceof Error) {
    return { ok: false, error: response.message };
  }

  const text = await response.text().catch(() => null);

  if (text === null) {
    return {
      ok: false,
      error: `${call.procedure} answered ${response.status} with a body that broke off`,
    };
  }

  const answer = await decodeNixieAnswer(response.status, text);

  // the body itself never reaches the output, because a body can hold a session token
  if (!answer.ok) {
    const code = answer.code ?? 'with no error code';

    return { ok: false, error: `${call.procedure} answered ${response.status} ${code}` };
  }

  const value = call.parse(answer.output);

  return value === undefined
    ? {
        ok: false,
        error: `${call.procedure} answered an output that lacks the fields the check reads`,
      }
    : { ok: true, value };
}
