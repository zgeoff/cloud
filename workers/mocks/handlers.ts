import { http } from 'msw';
import { alertWebhookURL } from './alert-webhook-url.ts';
import { resolveTargetProbe } from './resolve-target-probe.ts';
import { targetStatuses } from './target-statuses.ts';
import { updateSentAlerts } from './update-sent-alerts.ts';

// A probe target answers the status stored for its URL. No handler matches a GET of a URL
// with no stored status, so the server reports it unhandled. The alert webhook records
// each post.
export const handlers = [
  http.get((info) => targetStatuses.has(info.request.url), resolveTargetProbe),
  http.post(alertWebhookURL, updateSentAlerts),
];
