import { HttpResponse } from 'msw';
import type { HttpResponseResolver } from 'msw';
import { sentAlerts } from './sent-alerts.ts';

type ResolverInfo = Parameters<HttpResponseResolver>[0];

// Records an alert post in sentAlerts and answers 204, as a Discord webhook answers a
// delivered message
export async function updateSentAlerts(info: ResolverInfo): Promise<HttpResponse<null>> {
  sentAlerts.push({
    contentType: info.request.headers.get('content-type'),
    body: await info.request.text(),
  });

  return new HttpResponse(null, { status: 204 });
}
