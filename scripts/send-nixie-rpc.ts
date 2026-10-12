import { buildNixieHeaders } from './build-nixie-headers.ts';
import { findJSONField } from './find-json-field.ts';

export interface NixieCall<T> {
  // nixie's origin; the ingress serves the API under /rpc
  readonly url: string;
  readonly token: string | null;

  // the procedure's path, such as sessions/enrol
  readonly procedure: string;
  readonly input: unknown;

  // reads the output the check needs, or undefined when the output lacks it
  readonly parse: (output: unknown) => T | undefined;
}

export type RPCResult<T> =
  | { readonly ok: true; readonly value: T }
  | { readonly ok: false; readonly error: string };

// Sends one call in oRPC's RPC protocol: the input goes as {json} in a POST to /rpc/<procedure>,
// and the output comes back as {json, meta}. A failed call answers an error status, with the
// error's code in the body when nixie defines it.
export async function sendNixieRPC<T>(call: Readonly<NixieCall<T>>): Promise<RPCResult<T>> {
  const response = await fetch(new URL(`/rpc/${call.procedure}`, call.url), {
    method: 'POST',
    headers: buildNixieHeaders(call.token),
    body: JSON.stringify({ json: call.input }),
  }).catch((error: unknown) => new Error(`${call.procedure} failed: ${String(error)}`));

  if (response instanceof Error) {
    return { ok: false, error: response.message };
  }

  const text = await response.text().catch(() => null);

  if (!response.ok || text === null) {
    return { ok: false, error: formatFailure(call.procedure, response.status, text) };
  }

  const value = call.parse(findJSONField(parseJSON(text), 'json'));

  return value === undefined
    ? { ok: false, error: `${call.procedure} answered an unexpected output: ${text.trim()}` }
    : { ok: true, value };
}

// an error's code when nixie defines it, or the body as it came
function formatFailure(procedure: string, status: number, text: string | null): string {
  if (text === null) {
    return `${procedure} answered ${status} with a body that broke off`;
  }

  const code = findJSONField(findJSONField(parseJSON(text), 'json'), 'code');

  return `${procedure} answered ${status} ${typeof code === 'string' ? code : text.trim()}`;
}

function parseJSON(text: string): unknown {
  try {
    const value: unknown = JSON.parse(text);

    return value;
  } catch {
    return undefined;
  }
}
