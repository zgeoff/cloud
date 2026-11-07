import { readFileSync } from 'node:fs';

// restore.sh runs pick-newest-set.ts from its own folder, so the restore Job's script volume holds
// both
const scriptFiles = ['restore.sh', 'pick-newest-set.ts'];

export function readNixieRestoreScripts(): Readonly<Record<string, string>> {
  return Object.fromEntries(
    scriptFiles.map((file) => [
      file,
      readFileSync(new URL(`../../deploy/nixie/backup/${file}`, import.meta.url), 'utf8'),
    ]),
  );
}
