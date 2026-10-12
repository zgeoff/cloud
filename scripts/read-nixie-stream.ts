import { buildNixieHeaders } from './build-nixie-headers.ts';
import type { RPCResult } from './send-nixie-rpc.ts';

export interface StreamHold {
  readonly url: string;
  readonly token: string;

  // the stream carries only records after this log sequence
  readonly afterSequence: number;
  readonly holdMs: number;
}

export interface StreamReport {
  readonly openMs: number;
  readonly keepalives: number;

  // the longest wait for a keepalive, from the open to the end
  readonly longestGapMs: number;
  readonly records: number;

  // held for the whole hold, closed early by nixie, or failed with the reason
  readonly end: 'held' | 'closed' | `failed: ${string}`;
}

// Holds the conversation thread's stream open, counting its keepalives and its records. oRPC sends
// the stream as server-sent events: a keepalive is a comment, and a record is a `message` event.
export async function readNixieStream(
  hold: Readonly<StreamHold>,
): Promise<RPCResult<StreamReport>> {
  const opened = await startStream(hold);

  if (!opened.ok) {
    return opened;
  }

  const timer = setTimeout(() => {
    opened.value.stop();
  }, hold.holdMs);

  const report = await readEvents(opened.value, {
    openedAt: performance.now(),
    buffer: '',
    keepaliveTimes: [],
    records: 0,
  });

  clearTimeout(timer);

  return { ok: true, value: report };
}

// The open stream's reader, behind functions. The hold's stop ends a read, so an end after the
// stop is a stream that stayed open.
interface StreamSource {
  readonly next: () => Promise<{ readonly done: boolean; readonly value?: string | undefined }>;
  readonly cancel: () => Promise<void>;
  readonly stop: () => void;
  readonly isHeld: () => boolean;
}

async function startStream(hold: Readonly<StreamHold>): Promise<RPCResult<StreamSource>> {
  const stopping = new AbortController();

  const response = await fetch(new URL('/rpc/log/follow', hold.url), {
    method: 'POST',
    headers: buildNixieHeaders(hold.token),
    body: JSON.stringify({ json: { afterSequence: hold.afterSequence, thread: 'conversation' } }),
    signal: stopping.signal,
  }).catch((error: unknown) => new Error(`log/follow failed: ${String(error)}`));

  if (response instanceof Error) {
    return { ok: false, error: response.message };
  }

  const type = response.headers.get('content-type') ?? '';

  if (!response.ok || !type.startsWith('text/event-stream') || response.body === null) {
    await response.body?.cancel();

    return { ok: false, error: `log/follow answered ${response.status} ${type}`.trim() };
  }

  const reader = response.body.pipeThrough(new TextDecoderStream()).getReader();

  return {
    ok: true,
    value: {
      next: () => reader.read(),
      cancel: () => reader.cancel(),
      stop: () => {
        stopping.abort();
      },
      isHeld: () => stopping.signal.aborted,
    },
  };
}

interface Tally {
  readonly openedAt: number;

  // the text after the last complete event, which waits for the next chunk
  readonly buffer: string;

  // when each keepalive arrived, in ms after the open
  readonly keepaliveTimes: readonly number[];
  readonly records: number;
}

async function readEvents(source: StreamSource, tally: Tally): Promise<StreamReport> {
  const chunk = await source.next().catch((error: unknown) => ({ failed: String(error) }));

  if ('failed' in chunk || chunk.done) {
    const cause: StreamReport['end'] = 'failed' in chunk ? `failed: ${chunk.failed}` : 'closed';
    const end = source.isHeld() ? 'held' : cause;

    return buildReport(tally, end);
  }

  const step = countChunk(tally, chunk.value ?? '');

  if (step.failure === null) {
    return readEvents(source, step.tally);
  }

  await source.cancel();

  return buildReport(step.tally, `failed: ${step.failure}`);
}

interface TallyStep {
  readonly tally: Tally;

  // why the stream ends, when an event ends it
  readonly failure: string | null;
}

// An event block ends at a blank line
function countChunk(tally: Tally, text: string): TallyStep {
  const blocks = (tally.buffer + text).split('\n\n');
  const buffer = blocks.pop() ?? '';

  return blocks.reduce<TallyStep>(
    (step, block) => (step.failure === null ? countEvent(step.tally, block) : step),
    { tally: { ...tally, buffer }, failure: null },
  );
}

function countEvent(tally: Tally, block: string): TallyStep {
  const lines = block.split('\n').filter((line) => line !== '');

  if (lines.length > 0 && lines.every((line) => line.startsWith(':'))) {
    const keepaliveTimes = [...tally.keepaliveTimes, performance.now() - tally.openedAt];

    return { tally: { ...tally, keepaliveTimes }, failure: null };
  }

  const event = lines
    .find((line) => line.startsWith('event:'))
    ?.slice('event:'.length)
    .trim();

  if (event === 'message') {
    return { tally: { ...tally, records: tally.records + 1 }, failure: null };
  }

  const name = event === undefined ? 'an event with no name' : `a ${event} event`;

  return { tally, failure: `the stream sent ${name}` };
}

function buildReport(tally: Tally, end: StreamReport['end']): StreamReport {
  const openMs = performance.now() - tally.openedAt;
  const times = [0, ...tally.keepaliveTimes, openMs];

  return {
    openMs,
    keepalives: tally.keepaliveTimes.length,
    longestGapMs: Math.max(...times.slice(1).map((time, index) => time - (times[index] ?? 0))),
    records: tally.records,
    end,
  };
}
