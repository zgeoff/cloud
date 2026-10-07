import { afterAll, afterEach } from 'bun:test';
import { server } from './node.ts';
import { sentAlerts } from './sent-alerts.ts';
import { targetStatuses } from './target-statuses.ts';

// The worker turns a failed probe into "unreachable", so an unhandled probe could still
// pass its test. Each unhandled request is recorded, and the test that sent it fails.
const unhandledRequests: string[] = [];

server.events.on('request:unhandled', (event) => {
  unhandledRequests.push(`${event.request.method} ${event.request.url}`);
});

server.listen({ onUnhandledRequest: 'error' });

afterEach(() => {
  server.resetHandlers();
  targetStatuses.clear();

  sentAlerts.length = 0;

  const unhandled = unhandledRequests.splice(0);

  if (unhandled.length > 0) {
    throw new Error(`the test sent requests no handler matched: ${unhandled.join(', ')}`);
  }
});

afterAll(() => {
  server.close();
});
