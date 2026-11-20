import { afterAll, afterEach, beforeAll } from 'bun:test';
import {
  commitStatuses,
  composeFiles,
  installationTokens,
  issueComments,
  pullRequestFiles,
  uninstalledRepos,
} from './constants.ts';
import { server } from './server.ts';
import { startSharedPreviewImpd, stopPreviewImpd } from './start-preview-impd.ts';

// A webhook answers 204 whatever GitHub said, so an unhandled request could still pass its test.
// Each unhandled request is recorded, and the test that sent it fails.
const unhandledRequests: string[] = [];

server.events.on('request:unhandled', (event) => {
  unhandledRequests.push(`${event.request.method} ${event.request.url}`);
});

// the only real traffic is loopback, to a test's stub impd through its own passthrough()
server.configure({ onUnhandledFrame: 'error' });
server.enable();

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

// each file gets one impd that its tests share, started here so the start stays out of the first
// test's time limit, and stopped with the file
beforeAll(startSharedPreviewImpd);

afterAll(async () => {
  await stopPreviewImpd();

  await server.disable();
});
