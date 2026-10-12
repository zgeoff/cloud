import { buildNixieHeaders } from './build-nixie-headers.ts';

export interface NixieCall {
  // nixie's origin; the ingress serves the API under /rpc
  readonly url: string;
  readonly token: string | null;

  // the procedure's path, such as sessions/enrol
  readonly procedure: string;
  readonly input: unknown;
}

export type RPCResult<T> =
  | { readonly ok: true; readonly value: T }
  | { readonly ok: false; readonly error: string };

// Sends one call in oRPC's RPC protocol: the input goes as {json} in a POST to /rpc/<procedure>,
// and the output comes back as {json, meta}. A failed call answers an error status, with the
// error's code in the body when nixie defines it.
export async function sendNixieRPC<T>(call: Readonly<NixieCall>): Promise<RPCResult<T>> {
  try {
    const response = await fetch(new URL(`/rpc/${call.procedure}`, call.url), {
      method: 'POST',
      headers: buildNixieHeaders(call.token),
      body: JSON.stringify({ json: call.input }),
    });

    const text = await response.text();

    return response.ok
      ? { ok: true, value: (JSON.parse(text) as { readonly json: T }).json }
      : { ok: false, error: `${call.procedure} answered ${response.status} ${findCode(text)}` };
  } catch (error) {
    return { ok: false, error: `${call.procedure} failed: ${(error as Error).message}` };
  }
}

// a defined error's code, or the body itself when it is not oRPC's error
function findCode(text: string): string {
  try {
    const body = JSON.parse(text) as { readonly json?: { readonly code?: unknown } };

    return typeof body.json?.code === 'string' ? body.json.code : text.trim();
  } catch {
    return text.trim();
  }
}
