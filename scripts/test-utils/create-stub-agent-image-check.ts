import { mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

export async function createStubAgentImageCheck(repo: string): Promise<string> {
  const path = join(repo, 'scripts/check-agent-image.ts');

  // with CHECK_STARTED naming a fifo, the stand-in writes a line there and hangs, so a test can
  // signal the build during the check
  const script = `import { writeFileSync } from 'node:fs';

const started = process.env['CHECK_STARTED'];

if (started === undefined) {
  console.log('== 0 failed');
} else {
  writeFileSync(started, 'started\\n');
  setInterval(() => {}, 60_000);
}
`;

  await mkdir(join(repo, 'scripts'), { recursive: true });
  await writeFile(path, script);

  return path;
}
