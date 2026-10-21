import type { NixieAPICheckCall } from './nixie-api/nixie-api-check-calls.ts';
import type { NixieReadProcedure } from './nixie-api/nixie-procedure-kinds.ts';
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
  const request = await encodeNixieRequest<NixieReadProcedure>({
    url: options.url,
    token: null,
    procedure: call.procedure,
    input: call.input,
    signal: AbortSignal.timeout(30_000),
  });

  const response = await options.send(request).catch((error: unknown) => new Error(String(error)));

  if (response instanceof Error) {
    return `failed: ${response.message}`;
  }

  const text = await response.text().catch(() => null);

  if (text === null) {
    return `answered ${response.status} with a body that broke off`;
  }

  const answer = await decodeNixieAnswer(response.status, text);

  // the body itself never reaches the output, because a successful answer can hold private data
  if (answer.ok) {
    return `answered ${response.status} with an output to a call without a session`;
  }

  if (!answer.isDefined) {
    return `answered ${response.status} with no error that nixie's contract defines, not 401 UNAUTHORIZED`;
  }

  if (response.status === 401 && answer.code === 'UNAUTHORIZED') {
    return null;
  }

  return `answered ${response.status} ${answer.code ?? 'with no error code'}, not 401 UNAUTHORIZED`;
}
