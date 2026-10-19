import { expect, test } from 'bun:test';
import { buildPodLogsPipeline } from './build-pod-logs-pipeline.ts';

test("it tails each pod container's log files from their end when it has no position, labelled with the namespace, pod, container, job and instance, and drops the atc gateway's approval lines and lines over an hour old", () => {
  expect(
    buildPodLogsPipeline({
      targets: 'discovery.kubernetes.web.targets',
      podLogRoot: '/node/log/pods',
      forwardTo: 'loki.write.central.receiver',
    }),
  ).toBe(`
discovery.relabel "pods" {
  targets = discovery.kubernetes.web.targets
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
  // the instance and job labels that Alloy's Kubernetes log source gives a pod's logs, which every
  // pod stream in Loki carries
  rule {
    source_labels = ["__meta_kubernetes_namespace", "__meta_kubernetes_pod_name", "__meta_kubernetes_pod_container_name"]
    separator     = "/"
    regex         = "(.+)/(.+)/(.+)"
    replacement   = "$1/$2:$3"
    target_label  = "instance"
  }
  rule {
    replacement  = "loki.source.kubernetes.pods"
    target_label = "job"
  }
  // the container's log files: one directory per pod, named <namespace>_<pod>_<uid>, and one per
  // container inside it
  rule {
    source_labels = ["__meta_kubernetes_namespace", "__meta_kubernetes_pod_name", "__meta_kubernetes_pod_uid", "__meta_kubernetes_pod_container_name"]
    separator     = "/"
    regex         = "(.+)/(.+)/(.+)/(.+)"
    replacement   = "/node/log/pods/\${1}_\${2}_\${3}/\${4}/*.log"
    target_label  = "__path__"
  }
}

// a file with no saved read position is read from its end, so a start with an empty position store
// reads no history. A running tailer reads a rotated log's old file to its end and the new file from
// its start, so a rotation loses no line. The lines a new container writes before Alloy finds its
// file never reach Loki, so Alloy looks each second.
loki.source.file "pods" {
  targets       = discovery.relabel.pods.output
  tail_from_end = true
  file_match {
    enabled     = true
    sync_period = "1s"
  }
  forward_to = [loki.process.pods.receiver]
}

loki.process "pods" {
  stage.cri {}

  // the CRI stage adds stream and the file source adds filename: neither is a label of a pod
  // stream, so the stdout and stderr lines of a container share one stream
  stage.label_drop {
    values = ["filename", "stream"]
  }

  // the atc gateway's OAuth approval lines stay in kubectl logs only, never in Loki
  stage.match {
    selector = "{namespace=\\"atc\\", container=\\"atc-gateway\\"} |~ \\"^atc-approval\\""
    action   = "drop"
  }

  // a line that Alloy reads late, such as the backlog after a long stop; Loki rejects what is
  // over an hour old, after it counts against the rate limit
  stage.drop {
    older_than          = "1h"
    drop_counter_reason = "too old"
  }
  forward_to = [loki.write.central.receiver]
}
`);
});
