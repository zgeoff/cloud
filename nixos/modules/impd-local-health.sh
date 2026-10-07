# Probe impd's /health on loopback and write node-exporter textfile metrics atomically.
# Inputs: IMPD_HEALTH_URL, TEXTFILE_DIR, and IMPD_HEALTH_TIMEOUT_SECONDS (curl's --max-time,
# default 5). Writes $TEXTFILE_DIR/impd_local_health.prom.

body=$(mktemp)
trap 'rm -f "$body"' EXIT

code=$(curl -s -o "$body" -w '%{http_code}' --max-time "${IMPD_HEALTH_TIMEOUT_SECONDS:-5}" "$IMPD_HEALTH_URL" || true)
code=${code:-000}

up=0
if [ "$code" = "200" ] && grep -q '"ready":true' "$body"; then
  up=1
fi

tmp=$(mktemp -p "$TEXTFILE_DIR" .impd_local_health.XXXXXX)
cat > "$tmp" <<EOF
# HELP impd_local_health_up impd answered /health on host loopback with 200 and ready true. Local only, not end-to-end HTTPS.
# TYPE impd_local_health_up gauge
impd_local_health_up $up
# HELP impd_local_health_status_code HTTP status of the last loopback probe, 0 when it got no answer.
# TYPE impd_local_health_status_code gauge
impd_local_health_status_code $((10#$code))
# HELP impd_local_health_last_check_timestamp_seconds When the last loopback probe ran.
# TYPE impd_local_health_last_check_timestamp_seconds gauge
impd_local_health_last_check_timestamp_seconds $(date +%s)
EOF
chmod 0644 "$tmp"
mv "$tmp" "$TEXTFILE_DIR/impd_local_health.prom"
