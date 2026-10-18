import { expect, test } from 'bun:test';
import { lokiValues } from './loki-values.ts';

test('it runs Loki as one replica on the filesystem, keeping 30 days at a capped ingestion rate, with no canary, gateway or caches', () => {
  expect(lokiValues).toStrictEqual({
    deploymentMode: 'SingleBinary',
    loki: {
      auth_enabled: false,
      commonConfig: { replication_factor: 1 },
      storage: { type: 'filesystem' },
      schemaConfig: {
        configs: [
          {
            from: '2026-10-01',
            store: 'tsdb',
            object_store: 'filesystem',
            schema: 'v13',
            index: { prefix: 'index_', period: '24h' },
          },
        ],
      },
      limits_config: {
        retention_period: '720h',
        ingestion_rate_mb: 0.004,
        ingestion_burst_size_mb: 32,
      },
      compactor: { retention_enabled: true, delete_request_store: 'filesystem' },
    },
    singleBinary: {
      replicas: 1,
      persistence: { size: '20Gi' },
      resources: { requests: { cpu: '50m', memory: '128Mi' }, limits: { memory: '384Mi' } },
    },
    read: { replicas: 0 },
    write: { replicas: 0 },
    backend: { replicas: 0 },
    chunksCache: { enabled: false },
    resultsCache: { enabled: false },
    gateway: { enabled: false },
    lokiCanary: { enabled: false },
    test: { enabled: false },
  });
});

test('it caps the log lines Loki can hold over 31 days, with snappy worst-case growth, below its 20Gi request', () => {
  const mib = 2 ** 20;
  const secondsOnDisk = 31 * 24 * 60 * 60;

  const worstCaseBytes =
    (lokiValues.loki.limits_config.ingestion_rate_mb * mib * secondsOnDisk +
      lokiValues.loki.limits_config.ingestion_burst_size_mb * mib) *
    (7 / 6);

  expect(lokiValues.singleBinary.persistence.size).toBe('20Gi');
  expect(worstCaseBytes).toBeLessThan(16 * 2 ** 30);
});

test('it lets one push through a burst of the hour of logs Loki accepts per stream, at the capped rate', () => {
  const hourAtCappedRateMiB = lokiValues.loki.limits_config.ingestion_rate_mb * 60 * 60;

  expect(lokiValues.loki.limits_config.ingestion_burst_size_mb).toBeGreaterThan(
    hourAtCappedRateMiB,
  );
});
