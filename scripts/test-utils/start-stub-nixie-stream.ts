import { buildStubNixieRecord } from './build-stub-nixie-record.ts';

export interface StubStreamOptions {
  // how often the stream sends a keepalive; null sends only the one at the open
  readonly keepaliveMs: number | null;

  // closes the stream this long after it opens; null keeps it open until the client leaves
  readonly closeAfterMs: number | null;

  // the client's abort, which ends the stream as nixie's does
  readonly signal: AbortSignal;
}

export interface StubStream {
  readonly body: ReadableStream<Uint8Array>;
  readonly sendRecord: (sequence: number) => void;
  readonly stop: () => void;
}

export function startStubNixieStream(options: StubStreamOptions): StubStream {
  const state: StreamState = { controller: null, timers: [], encoder: new TextEncoder() };

  const body = new ReadableStream<Uint8Array>({
    start: (controller) => {
      state.controller = controller;

      // oRPC 1.15.4 writes an empty comment at the open and at each keepalive
      sendText(state, ': \n\n');
    },
    cancel: () => {
      stopStream(state);
    },
  });

  if (options.keepaliveMs !== null) {
    state.timers.push(
      setInterval(() => {
        sendText(state, ': \n\n');
      }, options.keepaliveMs),
    );
  }

  if (options.closeAfterMs !== null) {
    state.timers.push(
      setTimeout(() => {
        stopStream(state);
      }, options.closeAfterMs),
    );
  }

  options.signal.addEventListener('abort', () => {
    stopStream(state);
  });

  return {
    body,
    sendRecord: (sequence) => {
      sendText(state, renderRecordEvent(sequence));
    },
    stop: () => {
      stopStream(state);
    },
  };
}

interface StreamState {
  controller: ReadableStreamDefaultController<Uint8Array> | null;
  readonly timers: ReturnType<typeof setTimeout>[];
  readonly encoder: TextEncoder;
}

function sendText(state: StreamState, text: string): void {
  state.controller?.enqueue(state.encoder.encode(text));
}

function stopStream(state: StreamState): void {
  for (const timer of state.timers) {
    clearTimeout(timer);
  }

  const open = state.controller;

  state.controller = null;

  try {
    open?.close();
  } catch {
    // the client cancelled the stream first
  }
}

function renderRecordEvent(sequence: number): string {
  const record = buildStubNixieRecord(sequence);
  const data = JSON.stringify({ json: { record }, meta: [[1, 'record', 'recordedAt']] });

  // oRPC 1.15.4's server-sent event: the record's sequence as its id, the record as {json, meta}
  return `event: message\nid: ${sequence}\ndata: ${data}\n\n`;
}
