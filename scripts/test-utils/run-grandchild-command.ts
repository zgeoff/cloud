import { onTestFinished } from 'bun:test';
import { mkdtemp, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { Runner } from '../run-process.ts';
import { runProcess } from '../run-process.ts';
import { removeDescendant } from './remove-descendant.ts';

// the grandchild holds the captured pipes, as an `impz exec` or a `curl` in a check does
export async function runGrandchildCommand(run: Runner, prelude: string): Promise<number> {
  const directory = await mkdtemp(join(tmpdir(), 'grandchild-command-'));

  const fifo = join(directory, 'started');
  const pidFile = join(directory, 'pid');

  onTestFinished(() => removeDescendant(directory, pidFile));

  await runProcess(['mkfifo', fifo]);

  const script = `(${prelude}echo $BASHPID > "$1"; echo > "$2"; exec sleep 30) & wait`;

  void run(['bash', '-c', script, 'bash', pidFile, fifo]);

  await readFile(fifo);

  const text = await readFile(pidFile, 'utf8');

  return Number(text);
}
