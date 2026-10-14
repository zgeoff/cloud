import { findJSONField } from './find-json-field.ts';
import type { ReadinessLine } from './format-readiness-line.ts';
import { missingGitHubTokenText, readGitHubToken } from './read-github-token.ts';
import type { Runner } from './run-process.ts';

const image = 'ghcr.io/zgeoff/atc-gateway';

// The package is private, so ghcr's pull token costs a GitHub token that reads packages, and the
// tag list answers 200 with it. A missing or refused credential FAILs, since the image may exist.
export async function checkGatewayImage(run: Runner): Promise<ReadinessLine> {
  const githubToken = await readGitHubToken(run);

  if (githubToken === undefined) {
    return { status: 'FAIL', text: `image ${image}: ${missingGitHubTokenText}` };
  }

  const status = await readTagListStatus(githubToken);

  if (status === 200) {
    return { status: 'ok', text: `image ${image} exists` };
  }

  return status === 401 || status === 403
    ? { status: 'FAIL', text: `image ${image}: ghcr.io refused the GitHub token (${status})` }
    : { status: 'missing', text: `image ${image}` };
}

// the tag list's status, the token realm's 401 or 403, or 0 when ghcr does not answer
async function readTagListStatus(githubToken: string) {
  try {
    const pullToken = await readPullToken(githubToken);

    if (typeof pullToken === 'number') {
      return pullToken;
    }

    const response = await fetch('https://ghcr.io/v2/zgeoff/atc-gateway/tags/list', {
      headers: { authorization: `Bearer ${pullToken}` },
      signal: AbortSignal.timeout(10_000),
    });

    return response.status;
  } catch {
    return 0;
  }
}

// ghcr's pull token, paid for with the GitHub token as basic auth's password, or the realm's 401
// or 403 when it refuses that token, or 0 when it hands out none
async function readPullToken(githubToken: string): Promise<string | number> {
  const realm = await fetch('https://ghcr.io/token?scope=repository:zgeoff/atc-gateway:pull', {
    headers: { authorization: `Basic ${btoa(`x:${githubToken}`)}` },
    signal: AbortSignal.timeout(10_000),
  });

  if (realm.status === 401 || realm.status === 403) {
    return realm.status;
  }

  const body: unknown = await realm.json();

  const token = findJSONField(body, 'token');

  return typeof token === 'string' && token !== '' ? token : 0;
}
