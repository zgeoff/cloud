// Grafana's Alloy chart, pinned once for the release and for the suite that renders it
// (test-alloy-chart.sh); bump deliberately
export const alloyChart = {
  chart: 'alloy',
  version: '1.13.0',
  repositoryOpts: { repo: 'https://grafana.github.io/helm-charts' },
};
