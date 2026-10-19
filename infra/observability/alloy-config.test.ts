import { expect, test } from 'bun:test';
import { alloyConfig } from './alloy-config.ts';
import { buildATCSecurityPipeline } from './build-atc-security-pipeline.ts';
import { buildPodLogsPipeline } from './build-pod-logs-pipeline.ts';

test("it tails every pod's log files from the node and the host journal into Loki, and counts the atc gateway's security events for Prometheus", () => {
  expect(alloyConfig).toBe(`
discovery.kubernetes "pods" {
  role = "pod"
}
${buildPodLogsPipeline({ targets: 'discovery.kubernetes.pods.targets', podLogRoot: '/var/log/pods', forwardTo: 'loki.write.default.receiver' })}${buildATCSecurityPipeline('/var/log/pods/atc_atc-gateway-*/atc-gateway/*.log')}
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
    url = "http://loki.observability.svc:3100/loki/api/v1/push"
  }
}
`);
});
