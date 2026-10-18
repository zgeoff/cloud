import { buildATCSecurityPipeline } from './build-atc-security-pipeline.ts';
import { lokiURL } from './loki-url.ts';

// Alloy keeps its read positions here, on the node, so a restart resumes where it stopped. Without
// a position, loki.source.kubernetes re-reads each container's whole log.
const storagePath = '/var/lib/alloy';

// The kubelet's log files of the atc gateway's container, under /var/log, which the chart mounts:
// one directory per pod, named <namespace>_<pod>_<uid>, and one per container inside it
const atcGatewayLogPath = '/var/log/pods/atc_atc-gateway-*/atc-gateway/*.log';

// Alloy as a DaemonSet: tail every pod's logs and the host's journal, and push them to Loki, and
// count atc's security events for Prometheus, which scrapes Alloy through the chart's ServiceMonitor
export const alloyValues = {
  alloy: {
    storagePath,
    configMap: {
      content: `
discovery.kubernetes "pods" {
  role = "pod"
}

discovery.relabel "pods" {
  targets = discovery.kubernetes.pods.targets
  rule {
    source_labels = ["__meta_kubernetes_namespace"]
    target_label  = "namespace"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_name"]
    target_label  = "pod"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_container_name"]
    target_label  = "container"
  }
}

loki.source.kubernetes "pods" {
  targets    = discovery.relabel.pods.output
  forward_to = [loki.process.pods.receiver]
}

// the atc gateway's OAuth approval lines stay in kubectl logs only, never in Loki
loki.process "pods" {
  stage.match {
    selector = "{namespace=\\"atc\\", container=\\"atc-gateway\\"} |~ \\"^atc-approval\\""
    action   = "drop"
  }
  // a start with no saved position reads each container's whole log; Loki
  // rejects what is over an hour old, after it counts against the rate limit
  stage.drop {
    older_than          = "1h"
    drop_counter_reason = "too old"
  }
  forward_to = [loki.write.default.receiver]
}
${buildATCSecurityPipeline(atcGatewayLogPath)}
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
`,
    },

    // /var/log from the host, read-only, for the journal
    mounts: { varlog: true, extra: [{ name: 'storage', mountPath: storagePath }] },

    // the Go runtime collects garbage harder as the heap nears GOMEMLIMIT, below the limit
    extraEnv: [{ name: 'GOMEMLIMIT', value: '300MiB' }],
    resources: { requests: { cpu: '20m', memory: '128Mi' }, limits: { memory: '384Mi' } },
  },
  serviceMonitor: { enabled: true },
  controller: {
    volumes: {
      extra: [{ name: 'storage', hostPath: { path: storagePath, type: 'DirectoryOrCreate' } }],
    },
  },
};
