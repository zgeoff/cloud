import type { ReadinessLine } from './format-readiness-line.ts';
import type { HostCheckIO } from './run-host-check.ts';
import { runHostCheck } from './run-host-check.ts';

// the cluster objects the deploy creates, each missing until it runs
const objects = ['namespace atc', 'storageclass local-path-retain', '-n atc deploy atc-gateway'];

export function checkGatewayObjects(io: Readonly<HostCheckIO>): Promise<readonly ReadinessLine[]> {
  return Promise.all(objects.map((object) => checkGatewayObject(io, object)));
}

async function checkGatewayObject(
  io: Readonly<HostCheckIO>,
  object: string,
): Promise<ReadinessLine> {
  const result = await runHostCheck(io, ['k3s', 'kubectl', 'get', ...object.split(' ')]);

  return result.exitCode === 0
    ? { status: 'ok', text: `exists: ${object}` }
    : { status: 'missing', text: object };
}
