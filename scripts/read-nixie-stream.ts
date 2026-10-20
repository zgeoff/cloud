import { encodeNixieRequest } from './nixie-api/nixie-rpc.ts';
import type { RPCResult } from './send-nixie-rpc.ts';

export interface StreamHold {
  readonly url: string;
  readonly token: string;

  readonly afterSequence: number;
  readonly holdMs: number;
}

export interface StreamReport {
  readonly openMs: number;
  readonly keepalives: number;

  readonly longestGapMs: number;
  readonly records: number;

  readonly end: 'held' | 'closed' | `failed: ${string}`;
}

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

// The hold's stop ends a read, so an end after the stop is a stream that stayed open.
interface StreamSource {
  readonly next: () => Promise<{ readonly done: boolean; readonly value?: string | undefined }>;
  readonly cancel: () => Promise<void>;
  readonly stop: () => void;
  readonly isHeld: () => boolean;
}

async function startStream(hold: Readonly<StreamHold>): Promise<RPCResult<StreamSource>> {
  const stopping = new AbortController();

  // the request goes through the adapter, and the body is read here, because the check counts the
  // keepalive comments that oRPC's own stream reader drops
  const request = await encodeNixieRequest({
    url: hold.url,
    token: hold.token,
    procedure: 'log/follow',
    input: { afterSequence: hold.afterSequence, thread: 'conversation' },
    signal: stopping.signal,
  });

  const response = await fetch(request).catch(
    (error: unknown) => new Error(`log/follow failed: ${String(error)}`),
  );

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

  readonly buffer: string;

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

interface TallyStep {
  readonly tally: Tally;

  readonly failure: string | null;
}

function countChunk(tally: Tally, text: string): TallyStep {
  // an SSE event block ends at a blank line
  const blocks = (tally.buffer + text).split('\n\n');
  const buffer = blocks.pop() ?? '';

  return blocks.reduce<TallyStep>(
    (step, block) => (step.failure === null ? countEvent(step.tally, block) : step),
    { tally: { ...tally, buffer }, failure: null },
  );
}

function countEvent(tally: Tally, block: string): TallyStep {
  const lines = block.split('\n').filter((line) => line !== '');

  // oRPC sends a keepalive as an SSE comment, and a record as a `message` event
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
