import { buildDashboard } from './build-dashboard.ts';

// The cloudflared dashboard: its tunnel connections, requests, errors and edge locations from
// Prometheus
export function buildCloudflaredDashboard(): Record<string, unknown> {
  return buildDashboard('cloudflared', 'prometheus', [
    {
      title: 'Tunnel HA connections',
      type: 'stat',
      expr: 'sum(cloudflared_tunnel_ha_connections)',
      width: 6,
      height: 5,
    },
    {
      title: 'Concurrent requests',
      type: 'stat',
      expr: 'sum(cloudflared_tunnel_concurrent_requests_per_tunnel)',
      width: 6,
      height: 5,
    },
    {
      title: 'Request errors (5m)',
      type: 'stat',
      expr: 'sum(increase(cloudflared_tunnel_request_errors[5m]))',
      width: 6,
      height: 5,
    },
    {
      title: 'Edge locations',
      type: 'stat',
      expr: 'count(cloudflared_tunnel_server_locations > 0)',
      width: 6,
      height: 5,
    },
    {
      title: 'Requests per second',
      type: 'timeseries',
      expr: 'sum by (pod) (rate(cloudflared_tunnel_total_requests[5m]))',
      legend: '{{pod}}',
      width: 12,
      height: 8,
    },
    {
      title: 'Responses by status code',
      type: 'timeseries',
      expr: 'sum by (status_code) (rate(cloudflared_tunnel_response_by_code[5m]))',
      legend: '{{status_code}}',
      width: 12,
      height: 8,
    },
  ]);
}
