import type { Provider } from '@pulumi/kubernetes';
import { ConfigMap } from '@pulumi/kubernetes/core/v1';
import type { Namespace } from '@pulumi/kubernetes/core/v1';
import { buildCloudflaredDashboard } from './build-cloudflared-dashboard.ts';
import { buildHostCPUDashboard } from './build-host-cpu-dashboard.ts';
import { buildIMPDashboard } from './build-imp-dashboard.ts';

export function createDashboards(ns: Namespace, cluster: Provider): ConfigMap[] {
  const dashboards = {
    imp: buildIMPDashboard(),
    cloudflared: buildCloudflaredDashboard(),
    'host-cpu': buildHostCPUDashboard(),
  };

  return Object.entries(dashboards).map(
    ([name, dashboard]) =>
      new ConfigMap(
        `dashboard-${name}`,
        {
          metadata: {
            name: `dashboard-${name}`,
            namespace: ns.metadata.name,

            // Grafana's dashboard sidecar loads every ConfigMap labelled grafana_dashboard=1
            labels: { grafana_dashboard: '1' },
          },
          data: { [`${name}.json`]: JSON.stringify(dashboard) },
        },
        { provider: cluster },
      ),
  );
}
