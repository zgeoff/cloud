import { match } from 'ts-pattern';
import type { NixieAnswer } from './nixie-api/nixie-rpc.ts';

export type NixieReply =
  | { readonly kind: 'unreached'; readonly error: string }
  | { readonly kind: 'broken'; readonly status: number }
  | { readonly kind: 'answered'; readonly status: number; readonly answer: NixieAnswer };

// null when nixie refused the call with its own 401 UNAUTHORIZED, else why the check fails
export function classifyNixieRefusal(reply: NixieReply): string | null {
  return match(reply)
    .with({ kind: 'unreached' }, (unreached) => `failed: ${unreached.error}`)
    .with(
      { kind: 'broken' },
      (broken) => `answered ${String(broken.status)} with a body that broke off`,
    )
    .with({ kind: 'answered' }, (answered) => classifyAnswer(answered.status, answered.answer))
    .exhaustive();
}

function classifyAnswer(status: number, answer: NixieAnswer): string | null {
  return match(answer)
    .with(
      { ok: true },

      // the body itself never reaches the output, because a successful answer can hold private data
      () => `answered ${String(status)} with an output to a call without a session`,
    )
    .with({ ok: false }, (refusal) => classifyError(status, refusal))
    .exhaustive();
}

function classifyError(status: number, answer: Extract<NixieAnswer, { ok: false }>): string | null {
  if (!answer.isDefined) {
    return `answered ${String(status)} with no error that nixie's contract defines, not 401 UNAUTHORIZED`;
  }

  if (status === 401 && answer.code === 'UNAUTHORIZED') {
    return null;
  }

  return `answered ${String(status)} ${answer.code ?? 'with no error code'}, not 401 UNAUTHORIZED`;
}
