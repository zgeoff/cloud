import { checkNixieAPI } from './check-nixie-api.ts';
import { nixieAPICheckCalls } from './nixie-api/nixie-api-check-calls.ts';
import type { Runner } from './run-process.ts';
import { runProcess } from './run-process.ts';
import type { KubectlProxyStart } from './start-kubectl-proxy.ts';
import { startKubectlProxy } from './start-kubectl-proxy.ts';

export interface RunNixieAPICheckOptions {
  readonly run: Runner;
  readonly startProxy: () => Promise<KubectlProxyStart>;
  readonly printOut: (text: string) => void;
  readonly printErr: (text: string) => void;
}

// k3s's API server proxies to the Service nixie's port http, nixie's API, so the check needs no
// route to nixie beyond the k3s API that the deploy job already reaches
const nixieServicePath = '/api/v1/namespaces/nixie/services/http:nixie:http/proxy';

export async function runNixieAPICheck(
  options: Readonly<RunNixieAPICheckOptions>,
): Promise<number> {
  const rollout = await options.run(
    ['kubectl', '--namespace', 'nixie', 'rollout', 'status', 'statefulset/nixie', '--timeout=600s'],
    { timeoutMs: 660_000 },
  );

  if (rollout.exitCode !== 0) {
    options.printErr(
      `run-nixie-api-check: nixie's rollout did not finish (exit ${String(rollout.exitCode)}): ${rollout.stderr.toString().trim()}\n`,
    );

    return 1;
  }

  options.printOut(rollout.stdout.toString());

  const started = await options.startProxy();

  if (!started.ok) {
    options.printErr(`run-nixie-api-check: ${started.error}\n`);

    return 1;
  }

  const exitCode = await checkNixieAPI({
    url: `${started.proxy.url}${nixieServicePath}`,
    calls: nixieAPICheckCalls,
    printOut: options.printOut,
    printErr: options.printErr,
  });

  await started.proxy.stop();

  return exitCode;
}

if (import.meta.main) {
  process.exitCode = await runNixieAPICheck({
    run: runProcess,
    startProxy: () =>
      startKubectlProxy({ argv: ['kubectl', 'proxy', '--port=0'], timeoutMs: 30_000 }),
    printOut: (text) => {
      process.stdout.write(text);
    },
    printErr: (text) => {
      process.stderr.write(text);
    },
  });
}
