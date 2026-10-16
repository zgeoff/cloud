import type { PreviewContract } from './parse-preview-contract.ts';
import type { PreviewDeps } from './types.ts';

interface HealthWait {
  readonly imp: string;
  readonly contract: PreviewContract;
  readonly windowMs: number;
}

export interface HealthResult {
  readonly healthy: boolean;

  // the URL the probes asked, through impd's proxy
  readonly url: string;

  // the last failed probe's answer, such as `502 Nothing answers in the imp`, or null when healthy
  readonly lastAnswer: string | null;
}

// Polls the health path through the imp's own HTTPS name, the route impd's proxy takes after the
// redirect, so an app on the guest's loopback alone fails here instead of answering 502 there.
// Healthy at the first 2xx or 3xx answer; unhealthy, with the last answer, once the window closes.
export async function waitForHealthy(deps: PreviewDeps, wait: HealthWait): Promise<HealthResult> {
  const deadline = deps.now().getTime() + wait.windowMs;
  const url = buildHealthURL(deps.settings.impDomain, wait.imp, wait.contract);
  const state: { lastAnswer: string | null } = { lastAnswer: null };

  while (deps.now().getTime() < deadline) {
    // oxlint-disable-next-line no-await-in-loop -- each probe waits for the pause before it
    const answer = await tryReadHealth(url);

    if (answer === null) {
      return { healthy: true, url, lastAnswer: null };
    }

    state.lastAnswer = answer;

    // oxlint-disable-next-line no-await-in-loop -- the pause sits between two probes
    await deps.sleep(deps.settings.healthPollMs);
  }

  return { healthy: false, url, lastAnswer: state.lastAnswer };
}

function buildHealthURL(impDomain: string, imp: string, contract: PreviewContract): string {
  return `https://${imp}.${impDomain}${contract.healthPath}`;
}

// null for a 2xx or 3xx answer, which `curl --fail` passed in the guest; otherwise the status and
// the start of the body, or why no answer came
async function tryReadHealth(url: string): Promise<string | null> {
  try {
    const response = await fetch(url, { redirect: 'manual', signal: AbortSignal.timeout(5000) });

    if (response.status >= 200 && response.status < 400) {
      await response.body?.cancel();

      return null;
    }

    const text = await response.text();

    const body = text.trim().slice(0, 200);

    return body === '' ? String(response.status) : `${response.status} ${body}`;
  } catch (error) {
    return error instanceof Error ? error.message : String(error);
  }
}
