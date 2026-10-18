# shellcheck shell=bash
# run_promtool_test <config dir> <test file>: runs `promtool test rules` on <test file>, a name inside
# <config dir>, with <config dir> mounted read-only as the working directory, so the test's rule
# files resolve beside it. It prints promtool's output and returns its exit status. The image is
# the Prometheus that kube-prometheus-stack's values pin for the chart version in
# infra/observability/create-metrics.ts, run as uid 65532 on a read-only root with no capabilities.
run_promtool_test() {
  local image='quay.io/prometheus/prometheus:v3.15.0@sha256:efd719c99d83b060d9daefdcf00360461adf279f45ef5391f8d111892118753e'
  # pulled first, so a cold image cache never writes its progress into the output a case compares
  docker pull -q "$image" > /dev/null
  docker run --rm --user 65532 --read-only --cap-drop ALL --security-opt no-new-privileges \
    --tmpfs /tmp -v "$1:/config:ro" -w /config --entrypoint promtool "$image" test rules "$2"
}
