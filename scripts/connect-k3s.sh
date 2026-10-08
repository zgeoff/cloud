#!/usr/bin/env bash
# After the NixOS install: store the k3s kubeconfig in 1Password (server set to the
# host's tailnet name) and reference it from .env, so Pulumi deploys the cluster
# workloads. Safe to run again: it replaces the stored kubeconfig. It stores before it
# writes .env, so a failed .env write leaves the stored copy current, and a second run
# after the fix completes it.
set -euo pipefail

host="${1:-geoffcloud}"
item="k3s-kubeconfig"
ref="op://cloud/$item/kubeconfig.yaml"

kubeconfig="$(ssh "root@$host" cat /etc/rancher/k3s/k3s.yaml | sed "s#https://127.0.0.1:6443#https://$host:6443#")"
if op item get "$item" --vault cloud > /dev/null 2>&1; then
  printf '%s\n' "$kubeconfig" | op document edit "$item" --vault cloud --file-name kubeconfig.yaml - > /dev/null
else
  printf '%s\n' "$kubeconfig" | op document create --vault cloud --title "$item" --file-name kubeconfig.yaml - > /dev/null
fi

grep -q '^K3S_KUBECONFIG=' .env || printf '\n# k3s API over the tailnet (#6)\nK3S_KUBECONFIG=%s\n' "$ref" >> .env
echo "stored $ref; run: bun run up -- --yes"
