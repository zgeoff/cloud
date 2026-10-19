import { HttpResponse } from 'msw';
import type { HttpResponseResolver } from 'msw';
import { sentAlerts } from './sent-alerts.ts';

type ResolverInfo = Parameters<HttpResponseResolver>[0];

export async function updateSentAlerts(info: ResolverInfo): Promise<HttpResponse<null>> {
  sentAlerts.push({
    contentType: info.request.headers.get('content-type'),
    body: await info.request.text(),
  });

  // a Discord webhook answers a delivered message with 204
  return new HttpResponse(null, { status: 204 });
}
