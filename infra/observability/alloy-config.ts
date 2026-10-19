import { buildATCSecurityPipeline } from './build-atc-security-pipeline.ts';
import { buildPodLogsPipeline } from './build-pod-logs-pipeline.ts';
import { lokiURL } from './loki-url.ts';

// The kubelet's pod log directories, under /var/log, which the chart mounts: one directory per pod,
// named <namespace>_<pod>_<uid>, and one per container inside it
const podLogRoot = '/var/log/pods';
const atcGatewayLogPath = `${podLogRoot}/atc_atc-gateway-*/atc-gateway/*.log`;

// Alloy's config: tail every pod's logs and the host's journal, and push them to Loki, and count
// atc's security events for Prometheus
export const alloyConfig = `
discovery.kubernetes "pods" {
  role = "pod"
}
${buildPodLogsPipeline({
  targets: 'discovery.kubernetes.pods.targets',
  podLogRoot,
  forwardTo: 'loki.write.default.receiver',
})}${buildATCSecurityPipeline(atcGatewayLogPath)}
// the host's journal: impd (imp-host logs to journald), k3s, tailscaled and the rest
// of the host, which no pod log covers
loki.source.journal "host" {
  path          = "/var/log/journal"
  // Loki rejects entries more than an hour behind a stream's newest; a start with
  // no saved position reads back max_age
  max_age       = "1h"
  relabel_rules = loki.relabel.journal.rules
  labels        = { job = "journal" }
  forward_to    = [loki.write.default.receiver]
}

loki.relabel "journal" {
  forward_to = []
  rule {
    source_labels = ["__journal__systemd_unit"]
    target_label  = "unit"
  }
}

loki.write "default" {
  endpoint {
    url = "${lokiURL}/loki/api/v1/push"
  }
}
`;
