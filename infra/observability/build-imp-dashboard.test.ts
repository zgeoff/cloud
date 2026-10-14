// the test lists every panel as one literal, so its body is long
/* oxlint-disable max-lines-per-function */
import { expect, test } from 'bun:test';
import { buildDashboard } from './build-dashboard.ts';
import { buildIMPDashboard } from './build-imp-dashboard.ts';

test("it charts impd's journal lines from Loki: volume, errors, boot and backup events, and the logs themselves", () => {
  expect(buildIMPDashboard()).toStrictEqual(
    buildDashboard('imp', 'loki', [
      {
        title: 'impd log lines',
        type: 'timeseries',
        expr: 'sum(count_over_time({job="journal", unit="imp-host.service"} [$__auto]))',
        legend: 'lines',
        width: 12,
        height: 8,
      },
      {
        title: 'impd errors and warnings',
        type: 'timeseries',
        expr: 'sum(count_over_time({job="journal", unit="imp-host.service"} |~ "(?i)error|fail|warning" [$__auto]))',
        legend: 'errors and warnings',
        width: 12,
        height: 8,
      },
      {
        title: 'Boot template restores',
        type: 'stat',
        expr: 'sum(count_over_time({job="journal", unit="imp-host.service"} |= "restored boot template" [$__range]))',
        width: 6,
        height: 5,
      },
      {
        title: 'Cold-boot fallbacks',
        type: 'stat',
        expr: 'sum(count_over_time({job="journal", unit="imp-host.service"} |= "booting the kernel" [$__range]))',
        width: 6,
        height: 5,
      },
      {
        title: 'Backups',
        type: 'stat',
        expr: 'sum(count_over_time({job="journal", unit="imp-host.service"} |~ "impd: backup: [0-9a-f]+:" [$__range]))',
        width: 6,
        height: 5,
      },
      {
        title: 'imp-docker-proxy log lines',
        type: 'stat',
        expr: 'sum(count_over_time({job="journal", unit="imp-docker-proxy.service"} [$__range]))',
        width: 6,
        height: 5,
      },
      {
        title: 'impd logs',
        type: 'logs',
        expr: '{job="journal", unit="imp-host.service"}',
        width: 24,
        height: 12,
      },
    ]),
  );
});
