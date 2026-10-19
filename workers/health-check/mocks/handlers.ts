import { http } from 'msw';
import { alertWebhookURL } from './alert-webhook-url.ts';
import { resolveTargetProbe } from './resolve-target-probe.ts';
import { targetStatuses } from './target-statuses.ts';
import { updateSentAlerts } from './update-sent-alerts.ts';

export const handlers = [
  // no handler matches a GET of a URL with no stored status, so the server reports it unhandled
  http.get((info) => targetStatuses.has(info.request.url), resolveTargetProbe),
  http.post(alertWebhookURL, updateSentAlerts),
];
