import { exposure, topology } from '@zgeoff/cloud-topology';
import type { TunnelRoute } from './build-tunnel-ingresses.ts';

export function buildPreviewWebhookRoute(): TunnelRoute {
  const route = exposure.entries.find((entry) => entry.name === 'preview-webhook-route');
  const listener = exposure.entries.find((entry) => entry.name === 'preview-webhook');

  if (route?.kind !== 'tunnel-hostname' || listener?.kind !== 'host-port') {
    throw new Error(
      'packages/topology/exposure.json needs the preview-webhook-route tunnel-hostname and the preview-webhook host-port',
    );
  }

  return {
    hostname: route.hostname,
    service: `http://${topology.tailnet.nodes.geoffcloud.address}:${listener.port}`,

    // no Access check: the service checks each delivery's signature itself
    path: '^/webhook$',
  };
}
