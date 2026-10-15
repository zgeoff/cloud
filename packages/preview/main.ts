import { loadPreviewConfig } from './load-preview-config.ts';
import { startPreviewService } from './start-preview-service.ts';

// The service's entry point, which systemd runs: configuration from the environment and the
// credential files, then both listeners until SIGTERM
const config = await loadPreviewConfig(process.env, (path) => Bun.file(path).text());

const service = startPreviewService(config);

process.once('SIGTERM', async () => {
  await service.stop();

  process.exit(0);
});
