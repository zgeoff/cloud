import { loadPreviewConfig } from './load-preview-config.ts';
import { startPreviewService } from './start-preview-service.ts';

const config = await loadPreviewConfig(process.env, (path) => Bun.file(path).text());

const service = startPreviewService(config);

process.once('SIGTERM', () => {
  void stopService(service);
});

async function stopService(running: ReturnType<typeof startPreviewService>): Promise<void> {
  await running.stop();

  process.exit(0);
}
