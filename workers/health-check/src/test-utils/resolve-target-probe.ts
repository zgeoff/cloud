import { HttpResponse } from 'msw';
import type { HttpResponseResolver } from 'msw';
import { targetStatuses } from './target-statuses.ts';

type ResolverInfo = Parameters<HttpResponseResolver>[0];

export function resolveTargetProbe(info: ResolverInfo): HttpResponse<null> {
  const status = getTargetStatus(info.request.url);

  return new HttpResponse(null, {
    status,

    // a real redirect carries a Location header
    headers: status >= 300 && status < 400 ? { location: 'https://example.invalid/' } : {},
  });
}

function getTargetStatus(url: string): number {
  const status = targetStatuses.get(url);

  // the handler matches only a URL with a stored status
  if (status === undefined) {
    throw new Error(`no status stored for ${url}`);
  }

  return status;
}
