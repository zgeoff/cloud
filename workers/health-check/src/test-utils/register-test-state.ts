import { afterEach } from 'bun:test';
import { sentAlerts } from './sent-alerts.ts';
import { targetStatuses } from './target-statuses.ts';

afterEach(() => {
  targetStatuses.clear();

  sentAlerts.length = 0;
});
