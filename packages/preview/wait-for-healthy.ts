import type { PreviewContract } from './parse-preview-contract.ts';
import type { PreviewDeps } from './types.ts';

interface HealthWait {
  readonly imp: string;
  readonly contract: PreviewContract;
  readonly windowMs: number;
}

// Polls the contract's health path from inside the guest, so the probe needs no route to the imp,
// and resolves true at the first answer or false once the window closes
export async function waitForHealthy(deps: PreviewDeps, wait: HealthWait): Promise<boolean> {
  const deadline = deps.now().getTime() + wait.windowMs;

  const probe = [
    'curl',
    '--fail',
    '--silent',
    '--output',
    '/dev/null',
    '--max-time',
    '5',
    buildHealthURL(wait.contract),
  ];

  while (deps.now().getTime() < deadline) {
    // oxlint-disable-next-line no-await-in-loop -- each probe waits for the pause before it
    const answer = await deps.impd.runCommand(wait.imp, probe);

    if (answer.code === 0) {
      return true;
    }

    // oxlint-disable-next-line no-await-in-loop -- the pause sits between two probes
    await deps.sleep(deps.settings.healthPollMs);
  }

  return false;
}

export function buildHealthURL(contract: PreviewContract): string {
  return `http://127.0.0.1:${contract.port}${contract.healthPath}`;
}
