import { join } from 'node:path';
import { createFilesService } from './create-files-service.ts';
import { createUploadStore } from './create-upload-store.ts';
import { loadFilesConfig } from './load-files-config.ts';
import { readFreeBytes } from './read-free-bytes.ts';
import { runExpirySweep } from './run-expiry-sweep.ts';

// The entry point the container runs: configuration from the environment, the metadata file on
// the volume, the listener, and the expiry sweep at start and then hourly, until SIGTERM.
const config = loadFilesConfig(process.env);
const store = createUploadStore(join(config.dataDir, 'files.db'));

const service = createFilesService({
  store,
  dataDir: config.dataDir,
  tokenHashes: config.tokenHashes,
  publicURL: config.publicURL,
  now: () => new Date(),
  readFreeBytes: () => readFreeBytes(config.dataDir),
}).listen({ port: config.port, hostname: '0.0.0.0' });

runSweep();

const timer = setInterval(runSweep, 60 * 60 * 1000);

console.log(`files listening on port ${config.port}`);

process.once('SIGTERM', () => {
  clearInterval(timer);
  void stopService();
});

function runSweep(): void {
  const removed = runExpirySweep({
    store,
    filesDir: join(config.dataDir, 'files'),
    now: new Date(),
  });

  console.log(`expiry sweep: removed ${removed.length} uploads`);
}

async function stopService(): Promise<void> {
  await service.stop();

  store.close();
  process.exit(0);
}
