// Alloy as a DaemonSet: tail every pod's logs and the host's journal, and push them to Loki
export const alloyValues = {
  alloy: {
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
  forward_to = [loki.write.default.receiver]
}

// the host's journal: impd (imp-host logs to journald), k3s, tailscaled and the rest
// of the host, which no pod log covers
loki.source.journal "host" {
  path          = "/var/log/journal"
  // Loki rejects entries more than an hour behind a stream's newest; a restart
  // re-reads from max_age, since the read position is not persisted
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
`,
    },

    // /var/log from the host, read-only, for the journal
    mounts: { varlog: true },
    resources: { requests: { cpu: '20m', memory: '64Mi' }, limits: { memory: '192Mi' } },
  },
};
