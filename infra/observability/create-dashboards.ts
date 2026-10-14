import type { Provider } from '@pulumi/kubernetes';
import { ConfigMap } from '@pulumi/kubernetes/core/v1';
import type { Namespace } from '@pulumi/kubernetes/core/v1';
import { buildCloudflaredDashboard } from './build-cloudflared-dashboard.ts';
import { buildIMPDashboard } from './build-imp-dashboard.ts';

// Grafana's dashboard sidecar loads every ConfigMap labelled grafana_dashboard=1 (#27)
export function createDashboards(ns: Namespace, cluster: Provider): ConfigMap[] {
  const dashboards = { imp: buildIMPDashboard(), cloudflared: buildCloudflaredDashboard() };

  return Object.entries(dashboards).map(
    ([name, dashboard]) =>
      new ConfigMap(
        `dashboard-${name}`,
        {
          metadata: {
            name: `dashboard-${name}`,
            namespace: ns.metadata.name,
            labels: { grafana_dashboard: '1' },
          },
          data: { [`${name}.json`]: JSON.stringify(dashboard) },
        },
        { provider: cluster },
      ),
  );
}
