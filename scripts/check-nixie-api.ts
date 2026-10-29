import type { NixieReply } from './classify-nixie-refusal.ts';
import { classifyNixieRefusal } from './classify-nixie-refusal.ts';
import type { NixieAPICheckCall } from './nixie-api/nixie-api-check-calls.ts';
import type { NixieProcedure } from './nixie-api/nixie-rpc.ts';
import { decodeNixieAnswer, encodeNixieRequest } from './nixie-api/nixie-rpc.ts';

export interface CheckNixieAPIOptions {
  readonly url: string;
  readonly calls: readonly NixieAPICheckCall[];
  readonly send: (request: Request) => Promise<Response>;
  readonly printOut: (text: string) => void;
  readonly printErr: (text: string) => void;
}

export async function checkNixieAPI(options: Readonly<CheckNixieAPIOptions>): Promise<number> {
  const results = await Promise.all(
    options.calls.map(async (call) => ({
      procedure: call.procedure,
      failure: await readRefusal(options, call),
    })),
  );

  for (const result of results) {
    if (result.failure === null) {
      options.printOut(`${result.procedure}: refused without a session, as the contract says\n`);
    } else {
      options.printErr(`check-nixie-api: ${result.procedure} ${result.failure}\n`);
    }
  }

  if (results.some((result) => result.failure !== null)) {
    return 1;
  }

  options.printOut('nixie API check passed\n');

  return 0;
}

async function readRefusal(
  options: Readonly<CheckNixieAPIOptions>,
  call: NixieAPICheckCall,
): Promise<string | null> {
  const request = await encodeNixieRequest<NixieProcedure>({
    url: options.url,
    token: null,
    procedure: call.procedure,
    input: call.input,
    signal: AbortSignal.timeout(30_000),
  });

  const reply = await readReply(options.send, request);

  return classifyNixieRefusal(reply);
}

async function readReply(
  send: (request: Request) => Promise<Response>,
  request: Request,
): Promise<NixieReply> {
  const response = await send(request).catch((error: unknown) => new Error(String(error)));

  if (response instanceof Error) {
    return { kind: 'unreached', error: response.message };
  }

  const text = await response.text().catch(() => null);

  if (text === null) {
    return { kind: 'broken', status: response.status };
  }

  const answer = await decodeNixieAnswer(response.status, text);

  return { kind: 'answered', status: response.status, answer };
}
