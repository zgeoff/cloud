import { findJSONField } from './find-json-field.ts';
import type { ReadinessLine } from './format-readiness-line.ts';
import { missingGitHubTokenText, readGitHubToken } from './read-github-token.ts';
import type { Runner } from './run-process.ts';

const image = 'ghcr.io/zgeoff/atc-gateway';

export async function checkGatewayImage(run: Runner): Promise<ReadinessLine> {
  const githubToken = await readGitHubToken(run);

  if (githubToken === undefined) {
    return { status: 'FAIL', text: `image ${image}: ${missingGitHubTokenText}` };
  }

  const status = await readTagListStatus(githubToken);

  if (status === 200) {
    return { status: 'ok', text: `image ${image} exists` };
  }

  // a refused credential FAILs, since the image may exist
  return status === 401 || status === 403
    ? { status: 'FAIL', text: `image ${image}: ghcr.io refused the GitHub token (${status})` }
    : { status: 'missing', text: `image ${image}` };
}

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

async function readPullToken(githubToken: string): Promise<string | number> {
  const realm = await fetch('https://ghcr.io/token?scope=repository:zgeoff/atc-gateway:pull', {
    // ghcr's realm takes the GitHub token as basic auth's password
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
