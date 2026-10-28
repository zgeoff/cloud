import { afterAll, afterEach } from 'bun:test';
import {
  commitStatuses,
  composeFiles,
  installationTokens,
  issueComments,
  pullRequestFiles,
  uninstalledRepos,
} from './github-state.ts';
import { NativeWebSocket } from './native-web-socket.ts';
import { server } from './node.ts';

// A webhook answers 204 whatever GitHub said, so an unhandled request could still pass its test.
// Each unhandled request is recorded, and the test that sent it fails.
const unhandledRequests: string[] = [];

server.events.on('request:unhandled', (event) => {
  unhandledRequests.push(`${event.request.method} ${event.request.url}`);
});

// the import takes Bun's WebSocket before listen() replaces the global
void NativeWebSocket;

// the only real traffic is loopback, to a test's stub impd through its own passthrough()
server.listen({ onUnhandledRequest: 'error' });

afterEach(() => {
  server.resetHandlers();
  composeFiles.clear();
  pullRequestFiles.clear();
  uninstalledRepos.clear();

  issueComments.length = 0;
  commitStatuses.length = 0;
  installationTokens.length = 0;

  const unhandled = unhandledRequests.splice(0);

  if (unhandled.length > 0) {
    throw new Error(`the test sent requests no handler matched: ${unhandled.join(', ')}`);
  }
});

afterAll(() => {
  server.close();
});
