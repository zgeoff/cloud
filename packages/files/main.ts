import { join } from 'node:path';
import { createFilesService } from './create-files-service.ts';
import { createUploadStore } from './create-upload-store.ts';
import { loadFilesConfig } from './load-files-config.ts';
import { readFreeBytes } from './read-free-bytes.ts';
import { startExpirySweep } from './start-expiry-sweep.ts';

const config = loadFilesConfig(process.env);
const store = createUploadStore(join(config.dataDir, 'files.db'));

const service = createFilesService({
  store,
  dataDir: config.dataDir,
  tokenHashes: config.tokenHashes,
  publicURL: config.publicURL,
  now: () => new Date(),
  readFreeBytes: () => readFreeBytes(config.dataDir),
  writeBytes: (path, file) => Bun.write(path, file),
}).listen({ port: config.port, hostname: '0.0.0.0' });

const stopSweep = startExpirySweep({
  store,
  filesDir: join(config.dataDir, 'files'),
  now: () => new Date(),
  print: (line) => {
    console.log(line);
  },
  schedule: (run, intervalMs) => {
    const timer = setInterval(run, intervalMs);

    return () => {
      clearInterval(timer);
    };
  },
});

// before the listening line, so a SIGTERM that follows it always stops the service cleanly
process.once('SIGTERM', () => {
  stopSweep();
  void stopService();
});

console.log(`files listening on port ${config.port}`);

async function stopService(): Promise<void> {
  await service.stop();

  store.close();
  process.exit(0);
}
