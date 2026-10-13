import { HttpResponse } from 'msw';
import type { HttpResponseResolver } from 'msw';
import { targetStatuses } from './target-statuses.ts';

type ResolverInfo = Parameters<HttpResponseResolver>[0];

// Answers a probe with the status stored for its URL, with a Location header on a
// redirect status as a real redirect carries one
export function resolveTargetProbe(info: ResolverInfo): HttpResponse<null> {
  const status = getTargetStatus(info.request.url);

  return new HttpResponse(null, {
    status,
    headers: status >= 300 && status < 400 ? { location: 'https://example.invalid/' } : {},
  });
}

// the handler matches only a URL with a stored status
function getTargetStatus(url: string): number {
  const status = targetStatuses.get(url);

  if (status === undefined) {
    throw new Error(`no status stored for ${url}`);
  }

  return status;
}
