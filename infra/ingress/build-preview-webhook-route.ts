import { exposure, topology } from '@zgeoff/cloud-topology';
import type { TunnelRoute } from './build-tunnel-ingresses.ts';

// GitHub's pull_request webhooks for the preview service on the host, at the address and port the
// host's own service config reads. Only the /webhook path passes, and the service checks each
// delivery's signature itself.
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
    path: '^/webhook$',
  };
}
