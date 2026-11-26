# Observe geoff.cloud

Use this runbook to look at the estate's state, during an incident, after an alert or on a routine
check. Grafana, Loki, Prometheus and Alertmanager run in the cluster's `observability` namespace.
You reach Grafana from the tailnet, and Prometheus and Alertmanager through an SSH port forward.
Alertmanager sends alerts to Discord once you turn Discord alerts on in the stack config. The
external health check runs as a Cloudflare Worker outside the cluster. For how the parts fit
together, read [the observability architecture](../architecture/workloads/observability.md).

## Grafana

Grafana is at `http://geoffcloud:30300`, from the tailnet only. The user is `admin`. The password is
a secret stack output. This command prints it to your terminal:

```sh
cd infra
op run --env-file=../.env -- pulumi stack output --stack prod --show-secrets grafanaAdminPassword
```

The dashboards `imp` and `cloudflared` are provisioned from
`infra/observability/create-dashboards.ts`. Use Explore for ad hoc queries.

## Logs (Loki)

Query Loki from Grafana's Explore, with the `Loki` datasource:

| Logs                           | LogQL                                                                     |
| ------------------------------ | ------------------------------------------------------------------------- |
| impd                           | `{job="journal", unit="imp-host.service"}`                                |
| impd errors and warnings       | `{job="journal", unit="imp-host.service"} \|~ "(?i)error\|fail\|warning"` |
| k3s, tailscaled, any host unit | `{job="journal", unit="<unit>"}`                                          |
| a pod                          | `{namespace="<namespace>", pod="<pod>"}`                                  |
| cloudflared                    | `{namespace="ingress", container="cloudflared"}`                          |

## Metrics (Prometheus)

Query from Grafana's Explore, or reach Prometheus and Alertmanager directly. Neither has a NodePort,
so forward a port through SSH:

```sh
ssh -L 9090:localhost:9090 root@geoffcloud \
  k3s kubectl -n observability port-forward svc/prometheus-operated 9090
ssh -L 9093:localhost:9093 root@geoffcloud \
  k3s kubectl -n observability port-forward svc/alertmanager-operated 9093
```

Then open `http://localhost:9090` or `http://localhost:9093`.

| Question                       | PromQL                                   |
| ------------------------------ | ---------------------------------------- |
| Does impd answer locally?      | `impd_local_health_up`                   |
| Is the tunnel connected?       | `sum(cloudflared_tunnel_ha_connections)` |
| Which scrape targets are down? | `up == 0`                                |
| What is firing?                | `ALERTS{alertstate="firing"}`            |

## External health check

The Worker `geoff-cloud-health-check` logs each state change. Read its logs in the Cloudflare
dashboard, under Workers.

## Turn Discord alerts on or off

Set the `prod` stack's `discordAlerts` flag to send alerts to Discord, and remove it to stop every
message. Get the owner's approval before you change the flag or send a test alert, because each
alert reaches the owner's Discord. Each `op run` below fills `ALERT_WEBHOOK_URL` and
`ALERT_MENTION_USER_ID` from the 1Password items that `.env` maps them to.

1. Set the flag and land the change through a PR:

   ```sh
   cd infra
   op run --env-file=../.env -- pulumi config set --stack prod discordAlerts true
   ```

   This adds `geoff-cloud:discordAlerts: 'true'` to `infra/Pulumi.prod.yaml`.

2. From the repo root, run `bun run preview`, and check that it shows the new Secret
   `observability/alertmanager-discord`. It fails if `ALERT_WEBHOOK_URL` or `ALERT_MENTION_USER_ID`
   is empty.
3. Once the PR merges, the apply job applies the change. Alertmanager then sends every alert to
   Discord, except the chart's always-firing `Watchdog` and its `InfoInhibitor` helper.

To turn it off again, run `op run --env-file=../.env -- pulumi config rm --stack prod discordAlerts`
in `infra/`, and land it the same way. The external health check uses the same webhook either way.
