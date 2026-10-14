// Loki as one binary on one node: filesystem storage, a 30-day retention the compactor enforces,
// and no canary, gateway or caches
export const lokiValues = {
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
    limits_config: { retention_period: '720h' },
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
};
