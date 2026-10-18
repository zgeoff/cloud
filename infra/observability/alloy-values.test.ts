import { expect, test } from 'bun:test';
import { alloyValues } from './alloy-values.ts';

test("it tails every pod's logs and the host journal into Loki from saved positions, dropping lines over an hour old and the atc gateway's approval lines", () => {
  expect(alloyValues).toStrictEqual({
    alloy: {
      storagePath: '/var/lib/alloy',
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
`,
      },
      mounts: { varlog: true, extra: [{ name: 'storage', mountPath: '/var/lib/alloy' }] },
      extraEnv: [{ name: 'GOMEMLIMIT', value: '300MiB' }],
      resources: { requests: { cpu: '20m', memory: '128Mi' }, limits: { memory: '384Mi' } },
    },
    controller: {
      volumes: {
        extra: [
          { name: 'storage', hostPath: { path: '/var/lib/alloy', type: 'DirectoryOrCreate' } },
        ],
      },
    },
  });
});

test('it keeps its read positions on a directory of the node, which outlives the container and the pod', () => {
  expect(alloyValues.alloy.mounts.extra).toStrictEqual([
    { name: 'storage', mountPath: alloyValues.alloy.storagePath },
  ]);

  expect(alloyValues.controller.volumes.extra).toStrictEqual([
    {
      name: 'storage',
      hostPath: { path: alloyValues.alloy.storagePath, type: 'DirectoryOrCreate' },
    },
  ]);
});
