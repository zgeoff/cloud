import { findJSONField } from './find-json-field.ts';
import type { ReadinessLine } from './format-readiness-line.ts';

const image = 'ghcr.io/zgeoff/atc-gateway';

// ghcr hands out an anonymous pull token for a public image, and the tag list answers 200 with it
export async function checkGatewayImage(): Promise<ReadinessLine> {
  const exists = await hasImage();

  return exists
    ? { status: 'ok', text: `image ${image} exists` }
    : { status: 'missing', text: `image ${image}` };
}

async function hasImage() {
  try {
    const token = await readPullToken();

    if (token === '') {
      return false;
    }

    const response = await fetch('https://ghcr.io/v2/zgeoff/atc-gateway/tags/list', {
      headers: { authorization: `Bearer ${token}` },
      signal: AbortSignal.timeout(10_000),
    });

    return response.status === 200;
  } catch {
    return false;
  }
}

async function readPullToken() {
  const response = await fetch('https://ghcr.io/token?scope=repository:zgeoff/atc-gateway:pull', {
    signal: AbortSignal.timeout(10_000),
  });

  const body: unknown = await response.json();

  const token = findJSONField(body, 'token');

  return typeof token === 'string' ? token : '';
}
