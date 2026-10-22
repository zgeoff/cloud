// a hop-by-hop header, or one that describes a body the listener sends on as it arrived
const DROPPED_HEADERS = ['host', 'connection', 'keep-alive', 'transfer-encoding', 'content-length'];

// Bun's fetch decodes a compressed answer as it reads it, so the answer's encoding no longer holds
const ANSWER_DROPPED_HEADERS = [...DROPPED_HEADERS, 'content-encoding'];

export function buildForwardedHeaders(received: Headers, direction: 'call' | 'answer'): Headers {
  const headers = new Headers(received);

  for (const name of direction === 'call' ? DROPPED_HEADERS : ANSWER_DROPPED_HEADERS) {
    headers.delete(name);
  }

  return headers;
}
