import type { ProxyHold } from './create-spend-proxies.ts';
import type { SpendRefusal } from './render-spend-refusal.ts';

// holdToRelease is the hold to release at once; the hold of an answer with a body ends with its
// watched body, because a streamed reply can outlast the idle time
export type ProxyOutcome =
  | {
      readonly kind: 'refuse';
      readonly refusal: SpendRefusal;
      readonly holdToRelease: ProxyHold | null;
    }
  | {
      readonly kind: 'forward';
      readonly answer: Response;
      readonly hold: ProxyHold;
      readonly watchedBody: ReadableStream<Uint8Array> | null;
      readonly holdToRelease: ProxyHold | null;
    };

// the proxy is the spend cap, so a call whose proxy cannot start makes no model call
export function pickProxyOutcome(hold: ProxyHold | null, answer: Response | null): ProxyOutcome {
  if (hold === null) {
    return { kind: 'refuse', refusal: { kind: 'no-proxy' }, holdToRelease: null };
  }

  if (answer === null) {
    return { kind: 'refuse', refusal: { kind: 'no-answer' }, holdToRelease: hold };
  }

  const watchedBody = answer.body;

  return {
    kind: 'forward',
    answer,
    hold,
    watchedBody,
    holdToRelease: watchedBody === null ? hold : null,
  };
}
