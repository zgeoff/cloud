import { topology } from '@zgeoff/cloud-topology';
import { findJSONField } from './find-json-field.ts';
import type { ReadinessLine } from './format-readiness-line.ts';
import { readHostScript } from './read-host-script.ts';
import type { HostCheckIO } from './run-host-check.ts';
import { runHostCheck } from './run-host-check.ts';

// The cloud daemon drives impd on the host's loopback (tag:cloud has no grant to tag:imp), so the
// check reads impd's /health there and passes only a 200 whose JSON body has ready true. A failed
// check's line says why, never the body itself.
export async function checkImpdHealth(io: Readonly<HostCheckIO>): Promise<ReadinessLine> {
  const script = await readHostScript('read-impd-health.sh');

  const port = String(topology.imp.apiPort);

  const result = await runHostCheck(io, ['bash', '-s', '--', port], { stdin: script });

  const problem =
    result.exitCode === 0 ? findHealthProblem(result.stdout.toString()) : 'no answer (000)';

  return problem === undefined
    ? { status: 'ok', text: `impd is ready on ${io.host}'s loopback` }
    : { status: 'FAIL', text: `impd is not ready on ${io.host}'s loopback: ${problem}` };
}

// what read-impd-health.sh printed: the status on its first line, and impd's body after it
function findHealthProblem(output: string): string | undefined {
  const [code = '', ...rest] = output.split('\n');

  if (code !== '200') {
    return code === '' || code === '000' ? 'no answer (000)' : `status ${code}`;
  }

  const body = parseBody(rest.join('\n'));

  if (body === undefined) {
    return 'a 200 whose body is not JSON';
  }

  const ready = findJSONField(body, 'ready');

  if (ready === true) {
    return undefined;
  }

  return `a 200 whose body has ready ${pickReadyLabel(ready)}`;
}

function pickReadyLabel(ready: unknown): string {
  if (ready === false) {
    return 'false';
  }

  return ready === undefined ? 'missing' : 'that is not a boolean';
}

function parseBody(text: string): unknown {
  try {
    const value: unknown = JSON.parse(text);

    return value;
  } catch {
    return undefined;
  }
}
