# Observability

The estate watches itself from two places. A monitoring stack in k3s collects metrics and logs from
the cluster and the host, evaluates the alert rules and sends alerts to Discord. A Cloudflare Worker
probes the public route from Cloudflare's edge, because monitoring on the host cannot report that
the host is down. Every rule that rests on one probe's metric fires when that metric is missing as
well as when it is bad, so a probe, an exporter or a timer that stops reporting raises an alert
instead of reading as healthy.

## The stack in the cluster

The stack runs in the `observability` namespace:

- **kube-prometheus-stack** runs Prometheus, Alertmanager, Grafana, node-exporter and
  kube-state-metrics, and its default rules beside this repo's own.
- **Loki** stores logs on a filesystem volume as a single binary.
- **Alloy** runs on the node and ships every pod's logs and the host's systemd journal to Loki. impd
  logs to the journal through its container's unit, so impd's logs reach Loki the same way. Alloy
  drops the gateway's OAuth approval lines before they reach Loki, because each holds the code that
  approves a client's sign-in, so it stays in the pod's own log, which only a cluster admin reads.
- **Two blackbox exporters** run the probes that need a network path: one opens a TCP connection to
  each atc daemon on the gateway's path to it, and one fetches impd's health over HTTPS on the
  tailnet and requires a valid certificate and a ready answer.

Grafana's admin password is a secret Pulumi generates, and Grafana's NodePort answers only on the
tailnet. Its dashboards are provisioned from code. Metrics and logs sit on cluster volumes with no
backup, because losing them loses history and never service.

## Probes of impd

impd gets two probes, and each answers a different question. A host timer asks impd's health
endpoint on the loopback and writes the answer, with the time it ran, where node-exporter's textfile
collector reads it, so impd's own state reaches Prometheus even when the tailnet is down. The HTTPS
probe asks the same endpoint the way a client does, through impd's tailnet node and its certificate,
so it fails when clients cannot reach impd even though impd itself is healthy. The loopback probe
also carries a stale alert, which fires when the timer, the textfile or node-exporter stops, so a
dead probe never reads as a healthy impd.

## Alert rules

This repo's rules live in one PrometheusRule, built in code, and each rule that rests on one probe's
metric fires on its absence too. A rule over many targets, such as the one for scrape targets, fires
only on a bad value, because a target that vanishes is no longer a target. They cover:

- impd's loopback health, and the age of its last probe;
- impd's health over HTTPS on the tailnet;
- each atc daemon's reachability, at the severity the stack config sets per daemon, so the PC
  daemon, whose host sleeps, warns while the cloud daemon pages;
- the tunnel's connections, summed over both cloudflared replicas, because the tunnel serves while
  either is connected;
- each scrape target that is down, one alert per target, replacing the chart's rule that alerts on a
  ratio;
- a container whose last restart was an out-of-memory kill, because spaced restarts never trip the
  chart's crash-loop rule.

## Delivery

Alertmanager sends every alert to a Discord webhook once the stack config turns Discord alerts on,
and the webhook reaches it as a mounted Secret file, so the URL never appears in Alertmanager's
config. Two alerts never send: the chart's always-firing watchdog and its inhibition helper. With
Discord alerts off, every alert goes to a receiver that sends nothing, and alerts show only in
Prometheus and Alertmanager. Alertmanager keeps silences and notification state in memory-backed
storage, so a restart forgets them. Grafana does no alerting.

## The check from the edge

A Cloudflare Worker runs on a schedule and fetches the gateway's OAuth metadata through the public
route. It classifies the answer by its status: a tunnel error means the tunnel or the host is down,
a bad-gateway or gateway-timeout status means the gateway is down, a failed fetch means the route is
unreachable, and any other answer counts as up. The Worker keeps each target's last state in R2 and
acts only on a change, the recovery included, so it logs the change and posts it to the same webhook
Alertmanager uses, and a long outage sends one alert, not one per run. Pulumi bundles the Worker
with Bun at deploy time and uploads it with its bindings, so the Worker has no deploy of its own.
The Worker is its own workspace package, and its contract export names the bindings, the shape of
the targets and the entry module. Pulumi builds the bindings from that contract, so a renamed
binding fails the type check instead of the deployed Worker.
