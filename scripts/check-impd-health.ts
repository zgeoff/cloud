import { topology } from '@zgeoff/cloud-topology';
import type { ReadinessLine } from './format-readiness-line.ts';
import { readHostScript } from './read-host-script.ts';
import type { HostCheckIO } from './run-host-check.ts';
import { runHostCheck } from './run-host-check.ts';

// The cloud daemon drives impd on the host's loopback, since tag:cloud has no grant to tag:imp by
// imp's isolation design. So the check reads impd's /health there, as the local health probe does.
export async function checkImpdHealth(io: Readonly<HostCheckIO>): Promise<ReadinessLine> {
  const script = await readHostScript('read-impd-health.sh');

  const port = String(topology.imp.apiPort);

  const result = await runHostCheck(io, ['bash', '-s', '--', port], { stdin: script });

  const [code = '000', ready = '0'] = result.stdout.toString().trim().split(' ');
  const answer = result.exitCode === 0 ? code : '000';

  return answer === '200' && ready === '1'
    ? { status: 'ok', text: `impd is ready on ${io.host}'s loopback` }
    : { status: 'FAIL', text: `impd is not ready on ${io.host}'s loopback: ${answer}` };
}
