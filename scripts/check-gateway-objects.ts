import type { ReadinessLine } from './format-readiness-line.ts';
import type { HostCheckIO } from './run-host-check.ts';
import { runHostCheck } from './run-host-check.ts';

// the cluster objects the deploy creates, each missing until it runs
const objects = ['namespace atc', 'storageclass local-path-retain', '-n atc deploy atc-gateway'];

export async function checkGatewayObjects(
  io: Readonly<HostCheckIO>,
): Promise<readonly ReadinessLine[]> {
  const results = await Promise.all(
    objects.map((object) => runHostCheck(io, ['k3s', 'kubectl', 'get', ...object.split(' ')])),
  );

  return results.map((result, i) => {
    const object = objects[i] ?? '';

    return result.exitCode === 0
      ? { status: 'ok', text: `exists: ${object}` }
      : { status: 'missing', text: object };
  });
}
