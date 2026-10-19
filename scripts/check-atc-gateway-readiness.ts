import { checkATCDaemon } from './check-atc-daemon.ts';
import { checkGatewayHost } from './check-gateway-host.ts';
import { checkGatewayImage } from './check-gateway-image.ts';
import { checkGatewayInCluster } from './check-gateway-in-cluster.ts';
import { checkGatewayObjects } from './check-gateway-objects.ts';
import { checkGatewayRoute } from './check-gateway-route.ts';
import { checkImpdHealth } from './check-impd-health.ts';
import type { ReadinessLine } from './format-readiness-line.ts';
import { formatReadinessLine } from './format-readiness-line.ts';
import type { ScriptIO } from './run-or-exit.ts';
import { runProcess } from './run-process.ts';

export interface ATCGatewayReadinessOptions extends ScriptIO {
  readonly args: readonly string[];
}

export async function checkATCGatewayReadiness(
  options: Readonly<ATCGatewayReadinessOptions>,
): Promise<number> {
  if (options.args.length > 1) {
    options.printErr('usage: check-atc-gateway-readiness.ts [<host>]\n');

    return 2;
  }

  const io = { run: options.run, host: pickHost(options.args) };

  const checks: readonly (() => Promise<ReadinessLine | readonly ReadinessLine[]>)[] = [
    () => checkGatewayHost(io),
    () => checkGatewayObjects(io),
    () => checkGatewayImage(io.run),
    () => checkGatewayRoute(io.run),
    () => checkImpdHealth(io),
    () => checkATCDaemon(io),
    () => checkGatewayInCluster(io),
  ];

  let failures = 0;

  for (const check of checks) {
    const lines = [await check()].flat();

    failures += printLines(options, lines);
  }

  return failures;
}

function pickHost(args: readonly string[]) {
  const [host = ''] = args;

  return host === '' ? 'geoffcloud' : host;
}

function printLines(io: Readonly<ScriptIO>, lines: readonly ReadinessLine[]) {
  for (const line of lines) {
    io.printOut(formatReadinessLine(line));
  }

  return lines.filter((line) => line.status === 'FAIL').length;
}

if (import.meta.main) {
  process.exitCode = await checkATCGatewayReadiness({
    args: process.argv.slice(2),
    run: runProcess,
    printOut: (text) => {
      process.stdout.write(text);
    },
    printErr: (text) => {
      process.stderr.write(text);
    },
  });
}
