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
  const stopping = new AbortController();

  try {
    const response = await fetch(new URL('/rpc/log/follow', hold.url), {
      method: 'POST',
      headers: buildNixieHeaders(hold.token),
      body: JSON.stringify({ json: { afterSequence: hold.afterSequence, thread: 'conversation' } }),
      signal: stopping.signal,
    });

    const type = response.headers.get('content-type') ?? '';

    if (!response.ok || !type.startsWith('text/event-stream') || response.body === null) {
      await response.body?.cancel();

      return { ok: false, error: `log/follow answered ${response.status} ${type}`.trim() };
    }

    return { ok: true, value: await readStream(response.body, stopping, hold.holdMs) };
  } catch (error) {
    return { ok: false, error: `log/follow failed: ${(error as Error).message}` };
  }
}

interface StreamReading {
  readonly reader: ReadableStreamDefaultReader<Uint8Array>;
  readonly decoder: TextDecoder;
  readonly signal: AbortSignal;
  readonly openedAt: number;
  readonly keepaliveTimes: number[];
  buffer: string;
  records: number;
}

async function readStream(
  body: ReadableStream<Uint8Array>,
  stopping: AbortController,
  holdMs: number,
): Promise<StreamReport> {
  const timer = setTimeout(() => {
    stopping.abort();
  }, holdMs);

  const reading: StreamReading = {
    reader: body.getReader(),
    decoder: new TextDecoder(),
    signal: stopping.signal,
    openedAt: performance.now(),
    keepaliveTimes: [],
    buffer: '',
    records: 0,
  };

  const end = await readEvents(reading);

  clearTimeout(timer);

  return buildReport(reading, end);
}

// The hold's abort ends the read, so an end after the abort is a stream that stayed open
async function readEvents(reading: StreamReading): Promise<StreamReport['end']> {
  const chunk = await reading.reader.read().catch((error: unknown) => ({ failed: error }));

  if ('failed' in chunk) {
    return reading.signal.aborted ? 'held' : `failed: ${(chunk.failed as Error).message}`;
  }

  if (chunk.done) {
    return reading.signal.aborted ? 'held' : 'closed';
  }

  const failure = updateReadingFromChunk(reading, chunk.value);

  if (failure === null) {
    return readEvents(reading);
  }

  await reading.reader.cancel();

  return `failed: ${failure}`;
}

// An event block ends at a blank line, so the text after the last one waits for the next chunk
function updateReadingFromChunk(reading: StreamReading, chunk: Uint8Array): string | null {
  const blocks = (reading.buffer + reading.decoder.decode(chunk, { stream: true })).split('\n\n');

  reading.buffer = blocks.pop() ?? '';

  return blocks.map((block) => updateReading(reading, block)).find((text) => text !== null) ?? null;
}

// Counts one event block, and returns the reason when the block ends the stream
function updateReading(reading: StreamReading, block: string): string | null {
  const lines = block.split('\n').filter((line) => line !== '');

  if (lines.length > 0 && lines.every((line) => line.startsWith(':'))) {
    reading.keepaliveTimes.push(performance.now() - reading.openedAt);

    return null;
  }

  const event = lines
    .find((line) => line.startsWith('event:'))
    ?.slice('event:'.length)
    .trim();

  if (event === 'message') {
    reading.records += 1;

    return null;
  }

  return `the stream sent ${event === undefined ? 'an event with no name' : `a ${event} event`}`;
}

function buildReport(reading: StreamReading, end: StreamReport['end']): StreamReport {
  const openMs = performance.now() - reading.openedAt;
  const times = [0, ...reading.keepaliveTimes, openMs];

  return {
    openMs,
    keepalives: reading.keepaliveTimes.length,
    longestGapMs: Math.max(...times.slice(1).map((time, index) => time - (times[index] ?? 0))),
    records: reading.records,
    end,
  };
}
