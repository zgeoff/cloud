import { mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

// Writes <repo>/scripts/check-agent-image.ts, a stand-in for the commit's own check. Without
// CHECK_STARTED it passes and prints the real check's last line. With CHECK_STARTED naming a fifo,
// it writes a line there and hangs, so a test can signal build-agent-image.ts during the check.
export async function createStubAgentImageCheck(repo: string): Promise<string> {
  const path = join(repo, 'scripts/check-agent-image.ts');

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
