interface RecordedRequest {
  readonly method: string;
  readonly contentType: string | null;
  readonly body: string;
}

interface StubHTTPServer extends AsyncDisposable {
  readonly url: string;
  readonly requests: readonly RecordedRequest[];
}

// A stand-in for a remote HTTP endpoint on a real local port: it answers every request
// with status, and a Location header on a redirect status, and records each request's
// method, content type and body. Dispose it to stop the server.
export function startStubHTTPServer(status: number): StubHTTPServer {
  const requests: RecordedRequest[] = [];

  const server = Bun.serve({
    port: 0,
    hostname: '127.0.0.1',
    fetch: async (request) => {
      requests.push({
        method: request.method,
        contentType: request.headers.get('content-type'),
        body: await request.text(),
      });

      return new Response(null, {
        status,
        headers: status >= 300 && status < 400 ? { location: 'https://example.invalid/' } : {},
      });
    },
  });

  return {
    url: server.url.href,
    requests,
    [Symbol.asyncDispose]: () => server.stop(true),
  };
}
