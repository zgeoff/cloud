import { afterAll, afterEach } from 'bun:test';
import { server } from './node.ts';

// A script can turn a failed request into a result, so an unhandled request could still pass its
// test. Each unhandled request is recorded, and the test that sent it fails.
const unhandledRequests: string[] = [];

server.events.on('request:unhandled', (event) => {
  unhandledRequests.push(`${event.request.method} ${event.request.url}`);
});

// the only real traffic is loopback, through a test's own passthrough(); every other request
// goes to a handler
server.configure({ onUnhandledFrame: 'error' });
server.enable();

afterEach(() => {
  server.resetHandlers();

  const unhandled = unhandledRequests.splice(0);

  if (unhandled.length > 0) {
    throw new Error(`the test sent requests no handler matched: ${unhandled.join(', ')}`);
  }
});

afterAll(() => server.disable());
