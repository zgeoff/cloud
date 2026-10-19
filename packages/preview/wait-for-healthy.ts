import type { PreviewContract } from './parse-preview-contract.ts';
import type { PreviewDeps } from './types.ts';

interface HealthWait {
  readonly imp: string;
  readonly contract: PreviewContract;
  readonly windowMs: number;
}

export interface HealthResult {
  readonly healthy: boolean;

  readonly url: string;

  readonly lastAnswer: string | null;
}

export async function waitForHealthy(deps: PreviewDeps, wait: HealthWait): Promise<HealthResult> {
  const deadline = deps.now().getTime() + wait.windowMs;

  // impd's proxy takes this route after the redirect, so an app on the guest's loopback alone
  // fails here instead of answering 502 there
  const url = buildHealthURL(deps.settings.impDomain, wait.imp, wait.contract);
  const state: { lastAnswer: string | null } = { lastAnswer: null };

  while (deps.now().getTime() < deadline) {
    const answer = await tryReadHealth(url);

    if (answer === null) {
      return { healthy: true, url, lastAnswer: null };
    }

    state.lastAnswer = answer;

    await deps.sleep(deps.settings.healthPollMs);
  }

  return { healthy: false, url, lastAnswer: state.lastAnswer };
}

function buildHealthURL(impDomain: string, imp: string, contract: PreviewContract): string {
  return `https://${imp}.${impDomain}${contract.healthPath}`;
}

async function tryReadHealth(url: string): Promise<string | null> {
  try {
    const response = await fetch(url, { redirect: 'manual', signal: AbortSignal.timeout(5000) });

    // 2xx and 3xx, the answers `curl --fail` passes in the guest
    if (response.status >= 200 && response.status < 400) {
      await response.body?.cancel();

      return null;
    }

    const body = await response.text();

    return formatAnswer(response, body).slice(0, 400);
  } catch (error) {
    return error instanceof Error ? error.message : String(error);
  }
}

function formatAnswer(response: Response, body: string): string {
  if (!(response.headers.get('content-type') ?? '').startsWith('text/html')) {
    const text = body.trim().replaceAll(/\s+/gu, ' ');

    return text === '' ? String(response.status) : `${response.status} ${text}`;
  }

  // impd's proxy answers with an HTML page whose heading holds the status and whose paragraph
  // holds the cause
  return body
    .replaceAll(/<title>[^<]*<\/title>/giu, '')
    .replaceAll(/<[^>]*>/gu, '\n')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&amp;', '&')
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line !== '')
    .join(': ');
}
