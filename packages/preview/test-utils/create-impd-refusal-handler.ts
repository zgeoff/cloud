import type { HttpHandler } from 'msw';
import { HttpResponse, http, passthrough } from 'msw';
import { z } from 'zod';

// one impd procedure that refuses the calls naming one imp, a set number of times, with an oRPC
// error body; every other call passes through to the stub impd
export interface ImpdRefusal {
  readonly impdURL: string;
  readonly procedure: string;
  readonly imp: string;
  readonly times: number;
  readonly code: string;
  readonly status: number;
  readonly message: string;
  readonly data?: unknown;
}

const procedureBodySchema = z.object({ json: z.object({ name: z.string() }) });

export function createImpdRefusalHandler(refusal: ImpdRefusal): HttpHandler {
  const left = { count: refusal.times };

  return http.post(`${refusal.impdURL}/rpc/${refusal.procedure}`, async (info) => {
    const json: unknown = await info.request.clone().json();

    const body = procedureBodySchema.safeParse(json);
    const isRefused = left.count > 0 && body.success && body.data.json.name === refusal.imp;

    if (!isRefused) {
      return passthrough();
    }

    left.count -= 1;

    return HttpResponse.json(
      {
        json: {
          defined: true,
          code: refusal.code,
          status: refusal.status,
          message: refusal.message,
          ...(refusal.data !== undefined && { data: refusal.data }),
        },
      },
      { status: refusal.status },
    );
  });
}
