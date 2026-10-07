import { HttpResponse, http } from 'msw';
import { alertWebhookURL } from './alert-webhook-url.ts';
import { sentAlerts } from './sent-alerts.ts';
import { targetStatuses } from './target-statuses.ts';

// A probe target answers the status stored for its URL, with a Location header on a
// redirect status as a real redirect carries one. No handler matches a GET of a URL with
// no stored status, so the server reports it unhandled. The alert webhook records each post
// and answers 204, as a Discord webhook answers a delivered message.
export const handlers = [
  http.get(
    (info) => targetStatuses.has(info.request.url),
    (info) => {
      const status = getTargetStatus(info.request.url);

      return new HttpResponse(null, {
        status,
        headers: status >= 300 && status < 400 ? { location: 'https://example.invalid/' } : {},
      });
    },
  ),
  http.post(alertWebhookURL, async (info) => {
    sentAlerts.push({
      contentType: info.request.headers.get('content-type'),
      body: await info.request.text(),
    });

    return new HttpResponse(null, { status: 204 });
  }),
];

// the handler matches only a URL with a stored status
function getTargetStatus(url: string): number {
  const status = targetStatuses.get(url);

  if (status === undefined) {
    throw new Error(`no status stored for ${url}`);
  }

  return status;
}
