#!/usr/bin/env bun
// nixie's counting proxy as the preview service runs it: a JSON config, a loopback port from the
// kernel, and the proxy.started log line first on stdout. A request echoes back as JSON instead of
// a model reply, and a request to /exit ends the process, as a crash would.
import { parseArgs } from 'node:util';
import { z } from 'zod';

const configSchema = z.looseObject({
  listen: z.object({ hostname: z.string(), port: z.int() }),
  limits: z.object({ dollars: z.number() }),
  routes: z.record(z.string(), z.unknown()),
});

const args = parseArgs({ options: { config: { type: 'string' } } });

const stored: unknown = await Bun.file(args.values.config ?? '').json();

const config = configSchema.parse(stored);

const server = Bun.serve({
  hostname: config.listen.hostname,
  port: config.listen.port,
  fetch: answerRequest,
});

console.log(JSON.stringify({ event: 'proxy.started', port: server.port }));

process.once('SIGTERM', () => {
  void stopServer();
});

async function answerRequest(request: Request): Promise<Response> {
  const url = new URL(request.url);

  if (url.pathname === '/exit') {
    setTimeout(() => process.exit(0), 0);

    return new Response('exiting');
  }

  console.log(JSON.stringify({ event: 'request', path: url.pathname }));

  const body = await request.text();

  return Response.json({
    method: request.method,
    path: `${url.pathname}${url.search}`,
    body,
    routes: Object.keys(config.routes),
    limit: config.limits.dollars,
  });
}

async function stopServer(): Promise<void> {
  await server.stop(true);

  process.exit(0);
}
