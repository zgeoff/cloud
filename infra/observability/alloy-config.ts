import { alloyPaths } from './alloy-paths.ts';
import { buildATCSecurityPipeline } from './build-atc-security-pipeline.ts';
import { buildPodLogsPipeline } from './build-pod-logs-pipeline.ts';
import { lokiURL } from './loki-url.ts';

const atcGatewayLogPath = `${alloyPaths.podLogs}/atc_atc-gateway-*/atc-gateway/*.log`;

export const alloyConfig = `
discovery.kubernetes "pods" {
  role = "pod"
}
${buildPodLogsPipeline({
  targets: 'discovery.kubernetes.pods.targets',
  podLogRoot: alloyPaths.podLogs,
  positionsSeedFile: alloyPaths.podLogPositionsSeed,
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
